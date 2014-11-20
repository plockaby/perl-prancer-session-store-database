package Prancer::Session::Store::Database::Driver;

use strict;
use warnings FATAL => 'all';

use version;
our $VERSION = "1.00";

use Plack::Session::Store;
use parent qw(Plack::Session::Store);

use DBI;
use Storable qw(nfreeze thaw);
use MIME::Base64 qw(encode_base64 decode_base64);
use Try::Tiny;
use Carp;

# even though this *should* work automatically, it was not
our @CARP_NOT = qw(Prancer Try::Tiny);

sub new {
    my ($class, $config) = @_;

    # this is the only required field
    unless ($config->{'database'}) {
        croak "could not initialize session handler: no database name configured";
    }

    # initialize the serializer that will be used
    my $self = bless($class->SUPER::new(%{$config || {}}), $class);
    $self->{'_serializer'}      = sub { encode_base64(nfreeze(shift)) };
    $self->{'_deserializer'}    = sub { thaw(decode_base64(shift)) };

    $self->{'_database'}        = $config->{'database'};
    $self->{'_username'}        = $config->{'username'};
    $self->{'_password'}        = $config->{'password'};
    $self->{'_hostname'}        = $config->{'hostname'};
    $self->{'_port'}            = $config->{'port'};
    $self->{'_autocommit'}      = $config->{'autocommit'};
    $self->{'_charset'}         = $config->{'charset'};
    $self->{'_check_threshold'} = $config->{'connection_check_threshold'} // 30;
    $self->{'_table'}           = $config->{'table'} || "sessions";
    $self->{'_timeout'}         = $config->{'expiration_timeout'} // 1800;
    $self->{'_autopurge'}       = $config->{'autopurge'} // 1;
    $self->{'_application'}     = $config->{'application'};

    # store a pool of database connection handles
    $self->{'_handles'} = {};

    return $self;
}

sub handle {
    my $self = shift;

    # to be fork safe and thread safe, use a combination of the PID and TID
    # (if running with use threads) to make sure no two processes/threads share
    # a handle. implementation based on DBIx::Connector by David E. Wheeler
    my $pid_tid = $$;
    $pid_tid .= '_' . threads->tid() if $INC{'threads.pm'};

    # see if we have a matching handle
    my $handle = $self->{'_handles'}->{$pid_tid} || undef;

    if ($handle->{'dbh'}) {
        if ($handle->{'dbh'}{'Active'} && $self->{'_check_threshold'} &&
            (time - $handle->{'last_connection_check'} < $self->{'_check_threshold'})) {

            # the handle has been checked recently so just return it
            return $handle->{'dbh'};
        } else {
            if ($self->_check_connection($handle->{'dbh'})) {
                $handle->{'last_connection_check'} = time;
                return $handle->{'dbh'};
            } else {
                # try to disconnect but don't care if it fails
                if ($handle->{'dbh'}) {
                    try { $handle->{'dbh'}->disconnect() } catch {};
                }

                # try to connect again and save the new handle
                $handle->{'dbh'} = $self->_get_connection();
                return $handle->{'dbh'};
            }
        }
    } else {
        $handle->{'dbh'} = $self->_get_connection();
        if ($handle->{'dbh'}) {
            $handle->{'last_connection_check'} = time;
            $self->{'_handles'}->{$pid_tid} = $handle;
            return $handle->{'dbh'};
        }
    }

    return;
}

sub _get_connection {
    my $self = shift;
    my $dbh = undef;

    try {
        $dbh = DBI->connect(@{$self->{'_dsn'}}) || die "${\$DBI::errstr}\n";
    } catch {
        my $error = (defined($_) ? $_ : "unknown");
        croak "could not initialize database connection '${\$self->{'_connection'}}': ${error}";
    };

    return $dbh;
}

# Check the connection is alive
sub _check_connection {
    my $self = shift;
    my $dbh = shift;
    return 0 unless $dbh;

    if ($dbh->{'Active'} && (my $result = $dbh->ping())) {
        if (int($result)) {
            # DB driver itself claims all is OK, trust it
            return 1;
        } else {
            # it was "0 but true", meaning the DBD doesn't implement ping and
            # instead we got the default DBI ping implementation. implement
            # our own basic check, by performing a real simple query.
            return try {
                return $dbh->do('SELECT 1');
            } catch {
                return 0;
            };
        }
    }

    return 0;
}

sub fetch {
    my ($self, $session_id) = @_;
    my $dbh = $self->handle();
    my $result = undef;

    try {
        my $now = time();
        my $table = $self->{'_table'};
        my $application = $self->{'_application'};

        my $sth = $dbh->prepare(qq|
            SELECT data
            FROM ${table}
            WHERE id = ?
              AND application = ?
              AND timeout >= ?
        |);
        $sth->execute($session_id, $application, $now);
        my ($data) = $sth->fetchrow();
        $sth->finish();

        # deserialize the data if there is any
        $result = (defined($data) ? $self->{'_deserializer'}->($data) : undef);

        $dbh->commit();
    } catch {
        try { $dbh->rollback(); } catch {};

        my $error = (defined($_) ? $_ : "unknown");
        carp "error fetching from session: ${error}";
    };

    return $result;
}

sub store {
    my ($self, $session_id, $data) = @_;
    my $dbh = $self->handle();

    try {
        my $now = time();
        my $table = $self->{'_table'};
        my $application = $self->{'_application'};
        my $timeout = ($now + $self->{'_timeout'});
        my $serialized = $self->{'_serializer'}->($data);

        my $insert_sth = $dbh->prepare(qq|
            INSERT INTO ${table} (id, application, timeout, data)
            SELECT ?, ?, ?, ?
            WHERE NOT EXISTS (
                SELECT 1
                FROM ${table}
                WHERE id = ?
                  AND application = ?
                  AND timeout >= ?
            )
        |);
        $insert_sth->execute($session_id, $application, $timeout, $serialized, $session_id, $application, $now);
        $insert_sth->finish();

        my $update_sth = $dbh->prepare(qq|
            UPDATE ${table}
            SET timeout = ?, data = ?
            WHERE id = ?
              AND application = ?
              AND timeout >= ?
        |);
        $update_sth->execute($timeout, $serialized, $session_id, $application, $now);
        $update_sth->finish();

        # 10% of the time we will also purge old sessions
        if ($self->{'_autopurge'}) {
            my $chance = rand();
            if ($chance <= 0.1) {
                my $delete_sth = $dbh->prepare(qq|
                    DELETE
                    FROM ${table}
                    WHERE application = ?
                      AND timeout < ?
                |);
                $delete_sth->execute($application, $now);
                $delete_sth->finish();
            }
        }

        $dbh->commit();
    } catch {
        try { $dbh->rollback(); } catch {};

        my $error = (defined($_) ? $_ : "unknown");
        carp "error fetching from session: ${error}";
    };

    return;
}

sub remove {
    my ($self, $session_id) = @_;
    my $dbh = $self->handle();

    try {
        my $table = $self->{'_table'};
        my $application = $self->{'_application'};

        my $sth = $dbh->prepare(qq|
            DELETE
            FROM ${table}
            WHERE id = ?
              AND application = ?
        |);
        $sth->execute($session_id, $application);
        $sth->finish();

        $dbh->commit();
    } catch {
        try { $dbh->rollback(); } catch {};

        my $error = (defined($_) ? $_ : "unknown");
        carp "error fetching from session: ${error}";
    };

    return;
}

1;
