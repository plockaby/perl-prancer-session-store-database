package Prancer::Session::Store::Database;

use strict;
use warnings FATAL => 'all';

use version;
our $VERSION = "1.00";

1;

=head1 NAME

Prancer::Session::Store::Database

=head1 SYNOPSIS

This module implements a session handler by storing sessions in a database. It
creates its own database connection, separate from any existing database
connection, avoid any issues with transactions. It wraps all changes to the
database in transactions to ensure consistency.

This configuration expects a database table that looks like this:

    CREATE TABLE sessions (
        id CHAR(72) PRIMARY KEY,
        data TEXT,
        timeout integer DEFAULT date_part('epoch'::text, now()) NOT NULL
    );

Additional columns may be added as desired but they will not be used by the
session handler.

To use this session handler, add this to your configuration file:

    session:
        store:
            driver: Prancer::Session::Store::Database::Driver::DriverName
            options:
                table: sessions
                database: test
                username: test
                password: test
                hostname: localhost
                port: 5432
                charset: utf8
                connection_check_threshold: 10
                expiration_timeout: 3600
                autopurge: 0

=head1 OPTIONS

=over 4

=item table

The name of the table in your database to use to store sessions. This name may
include a schema name. Otherwise the default schema of the user will be used.
If this option is not provided the default will be C<sessions>.

=item database

B<REQUIRED> The name of the database to connect to.

=item username

The username to use when connecting. If this option is not set the default is
the user running the application server.

=item password

The password to use when connectin. If this option is not set the default is to
connect with no password.

=item hostname

The host name of the database server. If this option is not set the default is
to connect to localhost.

=item port

The port number on which the database server is listening. If this option is
not set the default is to connect on the database's default port.

=item charset

The character set to connect to the database with. If this is set to "utf8"
then the database connection will attempt to make UTF8 data Just Work if
available.

=item connection_check_threshold

This sets the number of seconds that must elapse between calls to get a
database handle before performing a check to ensure that a database connection
still exists and will reconnect if one does not. This handles cases where the
database handle hasn't been used in a while and the underlying connection has
gone away. If this is not set it will default to 30 seconds.

=item timeout

This the number of seconds a session should last in the database before it will
be automatically purged. The default is to purge sessions after 1800 seconds.

=item autopurge

This flag controls whether sessions will be automatically purged by Prancer.
If set to 1, the default, then on 10% of requests to your application, Prancer
will delete from the database any session that has timed out. If set to 0 then
sessions will never be removed from the database. Note that this doesn't
control whether sessions time out, only whether they get removed from the
database.

=back

=cut

