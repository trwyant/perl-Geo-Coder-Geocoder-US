package Geo::Coder::Geocoder::US;

use 5.006002;

use strict;
use warnings;

use Carp;
use LWP::UserAgent;
use Text::CSV;
use URI::Escape qw{ uri_escape };

our $VERSION = '0.003';

{

##  my %valid_arg = map { $_ => 1 } qw{ debug interface ua };
    my %valid_arg = map { $_ => 1 } qw{ debug ua };

    sub new {
	my ( $class, %args ) = @_;
	ref $class
	    and $class = ref $class;

##	exists $args{interface}
##	    or $args{interface} = 'namedcsv';

	exists $args{ua}
	    or $args{ua} = LWP::UserAgent->new();

	my $self = \%args;
	bless $self, $class;

	foreach my $key ( sort keys %args ) {
	    exists $valid_arg{$key}
		or croak "Argument $key is invalid";
	    $self->$key( $args{$key} );
	}

	# Fake up the interface attribute, which I would like to keep
	# internally for a bit, but am not sure I want to expose.

	$args{interface} = 'namedcsv';
	$args{_interface} = \&_geocode_namedcsv;

	return $self;
    }

}

sub debug {
    my ( $self, @args ) = @_;
    if ( @args ) {
	$self->{debug} = shift @args;
	return $self;
    } else {
	return $self->{debug};
    }
}

{

    use constant BASE_URL => 'http://geocoder.us/';
    use constant DELAY => 15;

    my $wait_for = time - DELAY;
    my %valid_arg = map { $_ => 1 } qw{ location };

    sub geocode {
	my ( $self, @args ) = @_;
	my %parm = @args % 2 ? ( location => @args ) : @args;
	defined $parm{location}
	    or croak "You must provide a location to geocode";
	$parm{location} = uri_escape( $parm{location} );

	my $now = time;
	{
	    $wait_for <= $now and last;
	    sleep $wait_for - $now;
	    $now = time;
	    redo;
	}
	$wait_for = $now + DELAY;

	my $rslt = $self->{response} = $self->{ua}->get(
	    BASE_URL. 'service/' . $self->{interface} .
	    '?address=' .
	    $parm{location}
	);
	$rslt->is_success()
	    or return;

	return $self->{_interface}->( $self, $rslt->content() );
    }

}

=begin comment

sub _geocode_csv {
    my ( $self, $content ) = @_;
    my $csv = $self->{_CSV} ||= Text::CSV->new( { binary => 1 } );
    my @rtn;
    foreach ( split qr{ \r \n? | \n }smx, $content ) {
	$csv->parse( $_ )
	    or croak $csv->error_diag();
	my %data;
	# TODO field names consistent with Geo::Coder::Many.
	@data{ qw< lat long address city state zip > } =
	    $csv->fields();
	defined $data{long}
	    or %data = ( error => $data{lat} );
	push @rtn, \%data;
    }
    return wantarray ? @rtn : $rtn[0];
}

=end comment

=cut

sub _geocode_namedcsv {
    my ( $self, $content ) = @_;
    my $csv = $self->{_CSV} ||= Text::CSV->new( { binary => 1 } );
    my @rtn;
    foreach ( split qr{ \r \n? | \n }smx, $content ) {
	$csv->parse( $_ )
	    or croak $csv->error_diag();
	my %data;
	foreach ( $csv->fields() ) {
	    s/ \A ( \w+ ) = //smx
		or next;
	    $data{$1} = $_;
	}
	push @rtn, \%data;
    }
    return wantarray ? @rtn : $rtn[0];
}

=begin comment

sub _geocode_rest {
    my ( $self, $content ) = @_;
    my $rslt;
    eval {
	$rslt = $self->_get_xml_parser->parse( $content );
	1;
    } or return [ { error => $content } ];
    _mung_tree( $rslt );
    my @rtn = _extract_point( $rslt );
    return wantarray ? @rtn : $rtn[0];
}

sub _extract_point {
    my ( $list ) = @_;
    my @pts;
    foreach my $tag ( @{ $list } ) {
	'ARRAY' eq ref $tag
	    or next;
	if ( $tag->[0] =~ m/ \b Point \z /smx ) {
	    my %pt;
	    foreach my $datum ( @{ $tag }[ 2 .. $#$tag ] ) {
		my $name = $datum->[0];
		$name =~ s/ [^:]* : //smx;
		$pt{$name} = $datum->[2];
	    }
	    push @pts, \%pt;
	} else {
	    push @pts, _extract_point( $tag );
	}
    }
    return @pts;
}

sub _mung_tree {
    my ( $list ) = @_;
    my @xfrm;
    my $inx = 0;
    while ( $inx <= $#$list ) {
	my $tag = $list->[$inx++];
	my $val = $list->[$inx++];
	if ( 'ARRAY' eq ref $val ) {
	    my @info = @{ $val };
	    my $attr = shift @info;
	    _mung_tree( \@info );
	    splice @info, 0, 0, $tag, $attr;
	    push @xfrm, \@info;
	} elsif ( ! ref $val && $val =~ m/ \S /smx ) {
	    $val =~ s/ \s+ / /smx;
	    $val =~ s/ \A \s+ //smx;
	    $val =~ s/ \s+ \z //smx;
	    if ( @xfrm && ! ref $xfrm[-1] ) {
		$xfrm[-1] .= ' ' . $val;
	    } else {
		push @xfrm, $val;
	    }
	}
    }
    @{ $list } = @xfrm;
    return $list;
}

# $ curl 'http://geocoder.us/service/rest?address=1600+Pennsylvania+Ave,+Washington+DC'
# <?xml version="1.0"?>
# <rdf:RDF
# xmlns:dc="http://purl.org/dc/elements/1.1/"
# xmlns:geo="http://www.w3.org/2003/01/geo/wgs84_pos#"
# xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
# >
# <geo:Point rdf:nodeID="aid83090669">
# <dc:description>1600 Pennsylvania Ave NW, Washington DC 20502</dc:description>
# <geo:long>-77.037684</geo:long>
# <geo:lat>38.898748</geo:lat>
# </geo:Point>
# </rdf:RDF>

{

    my $xml_parser_loaded;
    sub _get_xml_parser {
	my ( $self ) = @_;
	return ( $self->{_XML_PARSER} ||= do {
		defined $xml_parser_loaded
		    or eval {
		    require XML::Parser;
		    $xml_parser_loaded = 0;
		    1;
		}
		    or $xml_parser_loaded = $@;
		$xml_parser_loaded
		    and croak 'Unable to load XML::Parser';

		XML::Parser->new( Style	=> 'Tree' );
	    } );
    }

}

sub interface {
    my ( $self, @args ) = @_;
    if ( @args ) {
	my $interface = shift @args;
	my $code = $self->can( "_geocode_$interface" )
	    or croak "'interface' style '$interface' is not supported";
	$self->{interface} = $interface;
	$self->{_interface} = $code;
	return $self;
    } else {
	return $self->{interface};
    }
}

=end comment

=cut

sub response {
    my ( $self ) = @_;
    return $self->{response};
}

sub ua {
    my ( $self, @args ) = @_;
    if ( @args ) {
	my $ua = shift @args;
	local $@ = undef;
	eval { $ua->isa( 'LWP::UserAgent' ); 1 }
	    or croak "'ua' must be an LWP::UserAgent object";
	$self->{ua} = $ua;
	return $self;
    } else {
	return $self->{ua};
    }
}

1;

__END__

=head1 NAME

Geo::Coder::Geocoder::US - Geocode a location using L<http://geocoder.us/>

=head1 SYNOPSIS

 use Geo::Coder::Geocoder::US;
 use YAML;
 
 my $gc = Geo::Coder::Geocoder::US->new();
 foreach my $loc ( @ARGV ) {
     if ( my @rslt = $gc->geocode( $loc ) ) {
     } else {
         warn "Failed to geocode $loc: ",
	     $rslt->response()->status_line();
     }
 }

=head1 DESCRIPTION

This package geocodes addresses by looking them up on the
L<http://geocoder.us/> website. Because this site throttles access, this
class does to, to one request every 15 seconds.

=head1 METHODS

This class supports the following public methods:

=head2 new

 my $gc = Geo::Coder::Geocoder::US->new();

This static method instantiates a new C<Geo::Coder::Geocoder::US>
object. It takes named arguments C<debug>, C<interface>, and C<ua>, each
of which is handled by calling the same-named method. An attempt to use
any other named argument will result in an exception.

=head2 debug

This method accesses or modifies the C<debug> attribute of the object.
This attribute is unsupported in the sense that the author makes no
commitment about what will happen if it is set to a true value.

=head2 geocode

 my @rslt = $gc->geocode(
     '1600 Pennsylvania Ave, Washington DC' );
 my $rslt = $gc->geocode(
     '1600 Pennsylvania Ave, Washington DC' );

This method geocodes the location given in its argument. It can also be
called with named arguments:

 my @rslt = $gc->geocode(
     location => '1600 Pennsylvania Ave, Washington DC',
 );

The only supported argument name is C<location>; an attempt to use any
other argument name will result in an exception.

The return is an array of zero or more hash references, each containing
a geocoding of the location. Ambiguous locations will return more than
one geocoding. A lookup failure results in a single hash with an
C<{error}> key. If called in scalar context you get the first geocoding
(if any).

If there is a network problem of some sort, nothing is returned.
Regardless of the success or failure of the operation, the
L<HTTP::Response|HTTP::Response> object that represents the status of
the network call is accessible via the L<response()|/response> method.

=head2 response

 print 'Previous operation returned ',
     $gc->response()->status_line();

This method returns the L<HTTP::Response|HTTP::Response> object from the
previous call to L<geocode()|/geocode>. If no such call has been made,
the return is undefined.

=head2 ua

This method accesses or modifies the L<LWP::UserAgent|LWP::UserAgent>
object used to access L<http://geocoder.us/>.

If called as an accessor, it returns the object currently in use.

If called as a mutator, the argument must be an object of class
L<LWP::UserAgent|LWP::UserAgent> (or one of its subclasses).

=head1 SEE ALSO

The C<Geo-Coder-US> distribution by Schuyler Erle and Jo Walsh (see
L<http://search.cpan.org/dist/Geo-Coder-US/>) geocodes U.S. addresses
directly from the TIGER/Line database. I believe this underlies
L<http://geocode.us/>. You should prefer C<Geo-Coder-US> over this
package for bulk or otherwise serious geocoding.

The C<Geo-Coder-TomTom> distribution by gray (see
L<http://search.cpan.org/dist/Geo-Coder-TomTom>) uses the undocumented
REST interface to the TomTom route planner. It seems to offer coverage
in the U.S. approximately equivalent to this package, but without the
enforced delay between queries.

=head1 SUPPORT

Support is by the author. Please file bug reports at
L<http://rt.cpan.org>, or in electronic mail to the author.

=head1 AUTHOR

Thomas R. Wyant, III F<wyant at cpan dot org>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2011-2012 by Thomas R. Wyant, III

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl 5.10.0. For more details, see the full text
of the licenses in the directory LICENSES.

This program is distributed in the hope that it will be useful, but
without any warranty; without even the implied warranty of
merchantability or fitness for a particular purpose.

=cut

# ex: set textwidth=72 :
