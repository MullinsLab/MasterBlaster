#!/usr/bin/env perl
use 5.014;
use strict;
use warnings;
use FindBin qw< $Bin >;
use lib "$Bin/local/lib/perl5";

package MasterBlaster::Web {
    use Web::Simple;
    use Try::Tiny;
    use Path::Tiny;
    use Types::Standard qw< :types >;
    use HTTP::Status qw< :constants >;
    use Plack::App::File;
    use FindBin qw< $Bin >;
    use namespace::clean;

    has readme => (
        is      => 'ro',
        isa     => InstanceOf['Path::Tiny'],
        default => sub { path($Bin)->child("README.html") },
    );

    has blast_runner => (
        is      => 'ro',
        isa     => ClassName,
        default => sub { 'MasterBlaster::Runner' },
    );

    has db_path => (
        is       => 'ro',
        isa      => InstanceOf['Path::Tiny'],
        default  => sub { path($Bin)->child("db") },
    );

    has valid_dbs => (
        is  => 'lazy',
        isa => ArrayRef[Str],
    );

    sub _build_valid_dbs {
        my $self = shift;
        return [
            sort { lc($a) cmp lc($b) }
            map { $_->basename('.nhr') }
                path($self->db_path)->children(qr/\.nhr$/)
        ];
    }

    sub is_valid_db {
        my ($self, $db) = @_;
        state $valid = { map { $_ => 1 } @{ $self->valid_dbs } };
        return $valid->{$db};
    }

    sub is_valid_query {
        defined $_[1] and $_[1] =~ /\S/
    }

    sub dispatch_request {
        sub (GET + /databases) {
            [ 200,
              [ "Content-type" => "text/plain" ],
              [ map { "$_\n" } @{$_[0]->valid_dbs} ] ]
        },
        sub (POST + /blast + %:db=&:query=&:dust~&:max_target_seqs~) {
            my ($self) = @_;
            try {
                return $self->error(HTTP_BAD_REQUEST, "invalid db")
                    unless $self->is_valid_db( $_{db} );

                return $self->error(HTTP_BAD_REQUEST, "no query provided")
                    unless $self->is_valid_query( $_{query} );

                # Fully qualify database
                $_{db} = $self->db_path->child($_{db})->stringify;

                my $xml = $self->blast_runner->new(%_)->run;
                return [ HTTP_OK, ["Content-type" => "text/xml"], [ $xml ] ];
            } catch {
                warn "ERROR: $_\n";
                return $self->error(
                    HTTP_INTERNAL_SERVER_ERROR,
                    ($ENV{PLACK_ENV} || '') =~ /dev/
                        ? $_
                        : "Internal error"
                );
            };
        },
        sub (GET + /) {
            state $readme = Plack::App::File->new(file => $_[0]->readme);
            $readme;
        },
    }

    sub error {
        [ $_[1], [ 'Content-type' => 'text/plain' ], [ $_[2] ] ]
    }
}

package MasterBlaster::Runner {
    use Moo;
    use Types::Standard qw< :types >;
    use Types::Common::Numeric qw< :types >;
    use IPC::Run qw<>;
    use namespace::clean;

    has path => (
        is      => 'ro',
        isa     => Str,
        default => sub { 'blastn' },
    );

    has db => (
        is       => 'ro',
        isa      => Str,
        required => 1,
    );

    has query => (
        is       => 'ro',
        isa      => Str,
        required => 1,
    );

    has outfmt          => ( is => 'ro', isa => PositiveInt, default => sub { 5 } ); # XML
    has dust            => ( is => 'ro', isa => Str );
    has max_target_seqs => ( is => 'ro', isa => PositiveInt, default => sub { 10 } );

    sub opts {
        my $self = shift;
        return map {; "-$_" => $self->$_ }
              grep { defined $self->$_ }
                 qw[ db outfmt dust max_target_seqs ]
    }

    sub run {
        my $self = shift;
        my $blast = [ $self->path, $self->opts ];
        my ($xml, $err);
        IPC::Run::run($blast, \$self->query, \$xml, \$err, IPC::Run::timeout(240))
            or die "error running blast: $err";
        return $xml;
    }
}

MasterBlaster::Web->run_if_script;
