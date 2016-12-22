package TTMp32Gme::LibraryHandler;

use strict;
use warnings;

use File::Basename qw(basename dirname);
use Data::Dumper;
use Path::Class;
use List::MoreUtils qw(uniq);
use Cwd;

use Music::Tag ( traditional => 1 );
use Music::Tag::MusicBrainz;
use Music::Tag::MP3;
use Music::Tag::OGG;
use MP3::Tag;

#use Music::Tag:Amazon; #needs developer key
#use Music::Tag:LyricsFetcher; #maybe use this in a future release?

use TTMp32Gme::Build::FileHandler;

require Exporter;
our @ISA    = qw(Exporter);
our @EXPORT = qw(createLibraryEntry getAlbumList);

sub oidExist {
	my ( $oid, $dbh ) = $_[0];
	my @old_oids = map { @$_ }
		@{ $dbh->selectall_arrayref('SELECT oid FROM gme_library ORDER BY oid') };
	if ( grep( /^$oid$/, @old_oids ) ) {
		return 1;
	} else {
		return 0;
	}
}

sub newOID {
	my $dbh = $_[0];
	my $oid;
	my @old_oids =
		map { @$_ }
		@{ $dbh->selectall_arrayref('SELECT oid FROM gme_library ORDER BY oid DESC')
		};
	if (@old_oids) {
		if ( $old_oids[0] < 999 ) {

			#if we have free oids above the highest used oid, then use those
			$oid = $old_oids[0] + 1;
		} else {

			#if oid 999 is already in the database,
			#then look for oids freed by deleting old ones
			my %oid_test = map { $_ => 1 } @old_oids;
			my $new_oid = $old_oids[-1] + 1;
			print $new_oid . "\n";
			while ( ( $new_oid < 1001 ) and ( $oid_test{$new_oid} ) ) {
				$new_oid++;
			}
			if ( $new_oid == 1000 ) {

				#we still have not found a free oid,
				#look for free oids below the default oid
				$new_oid = $old_oids[-1] - 1;
				while ( $new_oid gt 0 and $oid_test{$new_oid} ) {
					$new_oid -= 1;
				}
				if ( $new_oid > 1 ) {
					$oid = $new_oid;
				} else {
					error(
						'could not find a free oid.'
							. ' Try deleting oids from your library.',
						1
					);
				}
			} else {
				$oid = $new_oid;
			}
		}
	} else {
		$oid = 920;
	}
	return $oid;
}

sub writeToDatabase {
	my ( $table, $data, $dbh ) = @_;
	my @fields = sort keys %$data;
	my @values = @{$data}{@fields};

	#print Dumper(@values);
	my $query = sprintf(
		"INSERT INTO $table (%s) VALUES (%s)",
		join( ", ", @fields ),
		join( ", ", map { '?' } @values )
	);

	#print $query. "\n";
	my $qh = $dbh->prepare($query);
	$qh->execute(@values);
}

sub createLibraryEntry {
	my ( $albumList, $dbh ) = @_;
	foreach my $album ( @{$albumList} ) {
		if ($album) {
			my $oid = newOID($dbh);
			my %albumData;
			my @trackData;
			my $pictureData;
			foreach my $fileId ( sort keys %{$album} ) {
				if ( $album->{$fileId} =~ /\.(mp3|ogg)$/i ) {

					#handle mp3 and ogg audio files
					my $info = Music::Tag->new( $album->{$fileId} );
					$info->get_tag( $album->{$fileId} );

					#fill in album info
					if ( !$albumData{'album_title'} && $info->album() ) {
						$albumData{'album_title'} = $info->album();
						$albumData{'path'}        = $albumData{'album_title'};
					}
					if ( !$albumData{'album_artist'} && $info->albumartist() ) {
						$albumData{'album_artist'} = $info->albumartist();
					} elsif ( !$albumData{'album_artist'} && $info->artist() ) {
						$albumData{'album_artist'} = $info->artist();
					}
					if ( !$albumData{'album_year'} && $info->year() ) {
						$albumData{'album_year'} = $info->get_year();
					}
					if ( !$albumData{'picture_filename'} && $info->picture_exists() ) {
						print "picture in metadata\n";
						if ( $info->picture_filename() ) {
							print "$info->picture_filename()\n";
							$albumData{'picture_filename'} = $info->picture_filename();
						} elsif ( $info->picture() ) {
							my %pic = $info->picture();
							print Dumper(%pic);
							$pictureData = $pic{'_Data'};
							$albumData{'picture_filename'} = basename( $pic{'filename'} );;
						}
					} elsif ( !$info->picture_exists() && $album->{$fileId} =~ /\.mp3$/i )
					{
						#Music::Tag::MP3 is not always reliable when extracting the picture,
						#try to use MP3::Tag directly.
						my $mp3 = MP3::Tag->new( $album->{$fileId} );
						$mp3->get_tags();
						my $id3v2_tagdata = $mp3->{ID3v2};
						my $apic          = $id3v2_tagdata->get_frame("APIC");
						$pictureData = $$apic{'_Data'};
						my $mimetype = $$apic{'MIME type'};
						$mimetype =~ s/.*\///;
						$albumData{'picture_filename'} = 'cover.' . $mimetype;
					}

					#fill in track info
					my %trackInfo = (
						'parent_oid' => $oid,
						'album'      => $info->album(),
						'artist'     => $info->artist(),
						'disc'       => $info->disc(),
						'duration'   => $info->duration(),
						'genre'      => $info->genre(),
						'lyrics'     => $info->lyrics(),
						'title'      => $info->title(),
						'track'      => $info->track(),
						'filename'   => $album->{$fileId},
					);
					push( @trackData, \%trackInfo );
				} elsif ( $album->{$fileId} =~ /\.(jpg|jpeg|tif|tiff|png|gif)$/i ) {

					#handle pictures
					open( my $file, '<', $album->{$fileId} );
					$pictureData = join( "", <$file> );
					close($file);
					$albumData{'picture_filename'} = basename( $album->{$fileId} );
				}
			}
			$albumData{'oid'}        = $oid;
			$albumData{'num_tracks'} = scalar(@trackData);
			if ( !$albumData{'album_title'} ) {
				$albumData{'path'}        = 'unknown';
				$albumData{'album_title'} = $albumData{'path'};
			}
			$albumData{'path'} = makeNewAlbumDir( $albumData{'path'} );
			if ( $albumData{'picture_filename'} and $pictureData ) {
				open(
					my $fh,
					'>',
					( file( $albumData{'path'}, $albumData{'picture_filename'} ) )
						->stringify
				);
				print $fh $pictureData;
				close($fh);
			}
			foreach my $track (@trackData) {
				$track->{'filename'} =
					moveToAlbum( $albumData{'path'}, $track->{'filename'} );
				writeToDatabase( 'tracks', $track, $dbh );
			}
			writeToDatabase( 'gme_library', \%albumData, $dbh );
		}
	}
	removeTempDir();
}

sub getAlbumList {
	my ( $dbh, $httpd ) = @_;
	my @albumList;
	my $albums =
		$dbh->selectall_hashref( q( SELECT * FROM gme_library ORDER BY oid ),
		'oid' );
	foreach my $oid ( sort keys %{$albums} ) {
		my $query = "SELECT * FROM tracks WHERE parent_oid=$oid ORDER BY track";

		#print $query."\n";
		my $tracks = $dbh->selectall_hashref( $query, 'track' );
		foreach my $track ( sort keys %{$tracks} ) {
			$albums->{$oid}->{ 'track_' . $track } = $tracks->{$track};
		}
		if ( $albums->{$oid}->{'picture_filename'} ) {
			my $picturePath = (
				file(
					cwd(), $albums->{$oid}->{'path'},
					$albums->{$oid}->{'picture_filename'}
				)
			)->stringify;
			open( my $fh, '<', $picturePath ) or die "Can't open '$picturePath': $!";
			my $pictureData = join( "", <$fh> );
			close($fh);
			$httpd->reg_cb(
				    '/assets/images/'
					. $oid . '/'
					. $albums->{$oid}->{'picture_filename'} => sub {
					my ( $httpd, $req ) = @_;
					$req->respond( { content => [ '', $pictureData ] } );
				}
			);
		}
		push( @albumList, $albums->{$oid} );
	}

	#print Dumper(@albumList);
	return \@albumList;
}

1;