package Koha::Plugin::Deichman::OverdueNoticeEmailer;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);
use CGI '-utf8';
use DateTime;
use Koha::Database;

## Here we set our plugin version
our $VERSION = 1.03;

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Overdue Notice Emailer',
    author          => 'Benjamin Rokseth',
    description     => 'This plugin takes a Koha patrons file and sends an email to the patrons found in the file',
    date_authored   => '2017-04-20',
    date_updated    => '2017-06-08',
    minimum_version => '16.11.060000',
    maximum_version => undef,
    version         => $VERSION,
};

## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);
    return $self;
}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install() {
    my ( $self, $args ) = @_;

    return 1;
}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
    my ( $self, $args ) = @_;

    return 1;
}

## Plugin configuration handler
sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    $cgi->charset('utf-8');

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        ## Grab the values we already have for our settings, if any exist
        $template->param( body      => $self->retrieve_data('body'), );
        $template->param( subject   => $self->retrieve_data('subject'), );

        print $cgi->header();
        print $template->output();
    }
    else {
        $self->store_data(
            {
                body               => $cgi->param('body'),
                subject            => $cgi->param('subject'),
                last_configured_by => C4::Context->userenv->{'number'},
            }
        );
    }

    $self->go_home();
}

# Report handler
sub report {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    $self->report_step1();
}

# Simple query producing list of overdues grouped by user
sub report_step1 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my @results;
    query({category => 'KL', foreach => sub {
        my ($res) = @_;
        push @results, $res;
    }});
    my $grouped_results = group_results_by_cardnumber(\@results);
    my $template = $self->get_template({ file => 'report-step1.tt' });
    $template->param(
        results => $grouped_results,
    );
    print $cgi->header(-charset => 'UTF-8');
    print $template->output();
}


# Tool handler
# - in general any plugin that modifies the Koha database should be considered a tool
sub tool {
    my ( $self, $args ) = @_;

    my $cgi = $self->{'cgi'};

    if ( $cgi->param('confirmed') ) { # confirm button in step 1 clicked
        $self->tool_step2();
    } else {
        $self->tool_step1();
    }

}

# Email confirmation step
sub tool_step1 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $body_template = $self->retrieve_data('body');
    my $subject       = $self->retrieve_data('subject');

    my @results = ();
    query({category => 'KL', foreach => sub {
        my ($res) = @_;
        push @results, $res;
    }});
    my $grouped_results = group_results_by_cardnumber(\@results);

    my @emails = ();
    while (my ($cardnumber, $items) = each %$grouped_results) {
        my $email = {
            name       => $items->[0]->{'name'},
            cardnumber => $cardnumber,
            subject    => $subject,
            email      => create_email_body($body_template, $cardnumber, $items)
        };
        push @emails, $email;
    }
    my $template = $self->get_template({ file => 'tool-step1.tt' });
    $template->param(
        emails => \@emails,
    );
    print $cgi->header(-charset => 'UTF-8');
    print $template->output();
}

# Send emails
sub tool_step2 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $body_template = $self->retrieve_data('body');
    my $subject       = $self->retrieve_data('subject');

    my @results = ();
    query({category => 'KL', foreach => sub {
        my ($res) = @_;
        push @results, $res;
    }});
    my $grouped_results = group_results_by_cardnumber(\@results);

    my $schema           = Koha::Database->new()->schema();
    my $message_queue_rs = $schema->resultset('MessageQueue');

    while (my ($cardnumber, $items) = each %$grouped_results) {
        my $email = create_email_body($body_template, $cardnumber, $items);
        $message_queue_rs->create(
            {
                borrowernumber         => $items->[0]->{'borrowernumber'},
                subject                => $subject,
                content                => $email,
                message_transport_type => 'email',
                status                 => 'pending',
                to_address             => $items->[0]->{'email'},
                from_address           => C4::Context->preference('KohaAdminEmailAddress'),
            }
        );
    }

    # print success page
    my $template = $self->get_template( { file => 'tool-step2.tt' } );

    print $cgi->header(-charset => 'UTF-8');
    print $template->output();
}

# compose email containing body from results
sub create_email_body {
    my ( $body_template, $cardnumber, $items ) = @_;
    my $email = Template->new();
    my $body;
    $email->process( \$body_template, {
        name => $items->[0]->{'name'},
        cardnumber => $cardnumber,
        items => $items
    }, \$body );
    return $body;
}

sub query {
    my ( $args ) = @_;
    my $foreach = $args->{foreach} or die "you must specify a callback";
    my $dbh = C4::Context->dbh;
    my $category = $args->{'category'};

    my $query = "
        SELECT b.borrowernumber,
               b.cardnumber,
               b.email,
               CONCAT(firstname, ' ', surname) AS name,
               bib.author,
               bib.title,
               i.biblionumber,
               i.barcode,
               i.copynumber,
               i.itype,
               iss.date_due
        FROM borrowers b
        JOIN issues iss USING (borrowernumber)
        JOIN items i USING (itemnumber)
        JOIN biblio bib ON (bib.biblionumber=i.biblionumber)
        WHERE b.categorycode= ?
          AND b.email IS NOT NULL
          AND (TO_DAYS(curdate()) - TO_DAYS(iss.date_due)) > 35;
    ";

    my $sth = $dbh->prepare($query);
    $sth->execute($category) or die "Error running query: $sth";

    while ( my $row = $sth->fetchrow_hashref() ) {
        $foreach->($row);
    }
}

# Return grouped results with cardnumber as hash key
sub group_results_by_cardnumber {
    my $res = shift;
    my %grouped;
    for (@{$res} ) {
        my $key = $_->{cardnumber} ? $_->{cardnumber} : 'unknown';
        push @{ $grouped{$key} }, $_;
    }
    return \%grouped
}

1;
