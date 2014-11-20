package Prancer::Session::Store::Database::Driver::SQLite;

use strict;
use warnings FATAL => 'all';

use version;
our $VERSION = '1.00';

use Prancer::Session::Store::Database::Driver;
use parent qw(Prancer::Session::Store::Database::Driver);

use Try::Tiny;
use Carp;

# even though this *should* work automatically, it was not
our @CARP_NOT = qw(Prancer Try::Tiny);

sub new {
    my $class = shift;

    try {
        require DBD::SQLite;
    } catch {
        my $error = (defined($_) ? $_ : "unknown");
        croak "could not initialize session handler: could not load DBD::SQLite: ${error}";
    };

    my $self = bless($class->SUPER::new(@_), $class);
    my $database  = $self->{'_database'};
    my $username  = $self->{'_username'};
    my $password  = $self->{'_password'};
    my $hostname  = $self->{'_hostname'};
    my $port      = $self->{'_port'};
    my $charset   = $self->{'_charset'};
    my $table     = $self->{'_table'};

    my $dsn = "dbi:SQLite:dbname=${database}";
    $dsn .= ";host=${hostname}" if defined($hostname);
    $dsn .= ";port=${port}" if defined($port);

    my $params = {
        'AutoCommit' => 0,
        'RaiseError' => 1,
        'PrintError' => 0,
    };
    if ($charset && $charset =~ /^utf8$/xi) {
        $params->{'sqlite_unicode'} = 1;
    }

    $self->{'_dsn'} = [ $dsn, $username, $password, $params ];
    return $self;
}

1;
