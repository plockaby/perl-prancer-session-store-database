package Prancer::Session::Store::Database::Driver::Pg;

use strict;
use warnings FATAL => 'all';

use version;
our $VERSION = "1.00";

use Prancer::Session::Store::Database::Driver;
use parent qw(Prancer::Session::Store::Database::Driver);

use Try::Tiny;
use Carp;

# even though this *should* work automatically, it was not
our @CARP_NOT = qw(Prancer Try::Tiny);

sub new {
    my $class = shift;

    try {
        require DBD::Pg;
    } catch {
        my $error = (defined($_) ? $_ : "unknown");
        croak "could not initialize session handler: could not load DBD::Pg: ${error}";
    };

    my $self = bless($class->SUPER::new(@_), $class);
    my $database  = $self->{'_database'};
    my $username  = $self->{'_username'};
    my $password  = $self->{'_password'};
    my $hostname  = $self->{'_hostname'};
    my $port      = $self->{'_port'};
    my $charset   = $self->{'_charset'};
    my $table     = $self->{'_table'};

    my $dsn = "dbi:Pg:dbname=${database}";
    $dsn .= ";host=${hostname}" if defined($hostname);
    $dsn .= ";port=${port}" if defined($port);

    my $params = {
        'AutoCommit' => 0,
        'RaiseError' => 1,
        'PrintError' => 0,
    };
    if ($charset && $charset =~ /^utf8$/xi) {
        $params->{'pg_enable_utf8'} = 1;
    }

    $self->{'_dsn'} = [ $dsn, $username, $password, $params ];
    return $self;
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
