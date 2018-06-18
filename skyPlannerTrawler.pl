#!/usr/bin/perl -w

use strict;
use JSON;
use HTTP::Request::Common;
use LWP::UserAgent;
use Cwd 'abs_path';
use Getopt::Long;

my $interface;
my $boxtypes;
my $searchtime;
my $clearprev;
my $help;
my $quiet;
my $resdir;
my $delfailed;
GetOptions (    "interface=s" => \$interface,
		"clear_previous" => \$clearprev,
		"stb_types=s" => \$boxtypes,
		"search_time=s" => \$searchtime,
		"results_directory=s" => \$resdir,
		"delete_failed" => \$delfailed,
		"help" => \$help,
		"quiet" => \$quiet,
		) or die "Error in command line arguments\n";


my $fullpath = abs_path(__FILE__);      			# Gets the full path to this script (including this script name)
my $maindir = $fullpath;
my $script = __FILE__;						# Just the script name
$script =~ s/.+\/([^\/]+)$/$1/;					# Format the script name to accommodate running from another directory
$maindir =~ s/\/$script$/\//;					# Get the main directory path that the script and associated files are in
my $filedir = $maindir . 'files/';				# The main directory for reference files
my $tmpdir = $filedir . 'tmp/';					# Temporary directory. Not currently used
my $exceptionfile = $filedir . 'skyPlusExceptionCodes.txt';	# Sky Plus exception codes reference file
my $skyqport = '9006';
my $skyplusport = '49153';

if ($help) {
	printHelp();
	exit;
}

##### Check system requirements
checkReqs();

##### Check specified network interface 
if (!$interface or $interface !~ /\S+/) {
	print "ERROR: No network interface provided\n\n";
	printHelp();
	die;
}

##### Check results directory if option provided
my $plannerdir = $maindir . 'stbPlannerData/';			# The DEFAULT directory to store STB planner contents (User can change this)
if ($resdir) {
	$resdir =~ s/\/*$//g;
	if (!-d $resdir) {
		print "ERROR: Provided results directory \"$resdir\" does not exist\n";
		exit;
	} elsif (!-W $resdir) {
		print "ERROR: Provided results directory \"$resdir\" not writeable by this user. Check permissions of the directory and try again\n";
		exit;
	} else {
		$plannerdir = $resdir . '/';
	}
}

##### Check stb_types option
my %boxtypes;
if ($boxtypes) {
	$boxtypes =~ s/\s+//g;
	if ($boxtypes !~ /Sky\+|SkyQ|SkyQSilver/i) {
		print "ERROR: Invalid stb_types option \"$boxtypes\". Check usage below\n\n";
		printHelp();
		exit;
	}
	my @btypes = split(',',$boxtypes);
	for (@btypes) {
		$boxtypes{lc($_)} = '1';
	}
}

##### Load Sky Plus exception codes
my %exceptions = loadSkyPlusExceptions();

##### Clear previous results and data files if selected
##### Use "unlink" with "glob" to delete all directory contents
##### Single quotes are required to accommodate filenames with spaces
if ($clearprev) {
	unlink glob "'$plannerdir*-plannerContents.txt'";
	unlink glob "'$tmpdir*.*'";	
}

##### Check search time
if ($searchtime) {
	die "Invalid search time \"$searchtime\"\n" if ($searchtime !~ /^\d+$/);
} else {
	$searchtime = '10';
}

##### Run the search
my $searchraw = `gssdp-discover -i $interface -t SkyBrowse:2 -n $searchtime` // '';
my @locations = $searchraw =~ m/Location.+\n/g;

my %stbs;
foreach my $loc (@locations) {
	chomp $loc;
	if ($loc =~ /Location:\s+(\S+)/) {
		my $address = $1;
		if ($address =~ /(\d{1,3}.\d{1,3}.\d{1,3}.\d{1,3})/) {
			$stbs{$1} = $address;
		}
	}
}

if (!%stbs) {
	print "No STBs found\n";
	exit;
}

my $count = '0';
foreach my $key (sort keys %stbs) {
	select STDOUT;
	my $xmlurl = $stbs{$key};
	my $xmlres = `wget -T 3 -t 1 -q -U SKY "$xmlurl" -O -` // '';
	if ($xmlres) {
		if ($xmlres =~ /^ERROR/) {
			print "ERROR: Unable to identify STB at $key:\n$xmlres\n";
			next;
		}
		if ($xmlres =~ m/\<friendlyName\>(\S+)\<\/friendlyName\>/) {
			my $type = $1;
			if ($type =~ /GATEWAY/i) {
				my $infourl = 'http://' . $key . ":$skyqport/as/system/information";
				my $infojson = getURL($infourl);
				if (!$infojson) {
					print "ERROR: Failed to get system information for STB at $key\n";
					next;
				} elsif ($infojson =~ /^ERROR/) {
					$infojson =~ s/\n{2,}/\n/g;	# Replace 2 or more consecutive line breaks with a single one
					print "$infojson\n";
					next;
				}
				my $stbinfo = parseInfoJSON(\$infojson);
				my ($qtype) = $$stbinfo =~ /STB Type = (.+)/;
				chomp $qtype;
				$qtype = lc($qtype);	# Force the text to lower case
				$qtype =~ s/\s+//g;	# Remove whitespace from the boxtype
				if ($boxtypes) {
					if (!exists $boxtypes{$qtype}) {
						next;					
					}
				}
				$count++;
				searchSkyQ(\$key,$stbinfo);
				next;
			} else {
				if ($boxtypes and !exists $boxtypes{'sky+'}) {
					next;
				}
				$count++;
				searchSkyPlus(\$key,\$xmlres);
				next
			}
		} else {
			print "ERROR: Unable to identify STB at $key:\n$xmlres\n";
		}
	} else {
		print "ERROR: Unable to identify STB at $key: No response from xml request\n";
	}
} ##### End of foreach loop for discovered STBs

select STDOUT;
if (!$quiet) {
	print "Finished. Processed $count STBs\n";
}
################################################################
######################### SUB ROUTINES #########################
################################################################

sub searchSkyQ {
	my ($ip,$stbinfo) = @_;
	my $infourl = 'http://' . $$ip . ":$skyqport/as/system/information";
	
	##### Get the serial number from the STB info and use that as the filename for its planners contents
	my ($fname) = $$stbinfo =~ m/Serial = (\w+)/;
	if (!$fname) {
		$fname = $$ip;
	}

	my $pvrfile = $plannerdir . $fname . '-plannerContents.txt';
	my $pvrfh;
	if (!open $pvrfh, '+>', $pvrfile) {
		print "ERROR: Unable to open $pvrfile: $!\n";
		return;
	}
	select $pvrfh;

	print "---------- Sky Q STB found at $$ip ----------\n";
	print $$stbinfo . "\n";

	#######################################
	##### Now get the planner content #####
	#######################################

	##### First get the info from the STB as to how many items are in the planner
	my $pvrinfourl = 'http://' . $$ip . ':' . $skyqport . '/as/pvr?limit=0&offset=0';
	my $rawinfo = getURL($pvrinfourl);
	if (!$rawinfo) {
		print "ERROR: Failed to retreive planner content info from STB\n";
		return;
	}
	
	my $pvrtotal = '0';
	if ($rawinfo =~ m/"totalPvrItems"\s*:\s*(\d+),/) {
		$pvrtotal = $1;
	}

	if (!$pvrtotal) {
		print "This STB has no planner content\n";
		return;
	}
	
	##### If the STB has planner content, process it now
	my $pvrurl = 'http://' . $$ip . ':' . $skyqport . '/as/pvr?limit=' . $pvrtotal . '&offset=0';

	my %pvr;
	my $content = getURL($pvrurl);
	if (!$content) {
		print "ERROR: Failed to retreive planner content data from STB\n";
		return;
	} elsif ($content =~ /^ERROR:/) {
		print "$content\n";
		return;
	}
	
	my $json = JSON->new->allow_nonref;
	
	%pvr = %{$json->pretty->decode($content)};
	if (!%pvr) {
		print "ERROR: Failed to decode JSON format pvr content from STB\n";
		return;
	}
	
	if (!exists $pvr{'pvrItems'}) {
		print "ERROR: No pvr items found\n";
		return;
	}
	
	my @items = @{$pvr{'pvrItems'}};
	foreach my $item (@items) {
		my %data = %{$item};
		my $title = $data{'t'} // 'N/A';
		my $src = $data{'src'} // 'N/A';
		my $pvrid = $data{'pvrid'} // 'N/A';
		my $status = $data{'status'} // 'N/A';
		my $schedstart = $data{'st'} // 'N/A';
		my $actstart = $data{'ast'} // 'N/A';
		my $channame = $data{'cn'} // 'N/A';
		my $channo = $data{'c'} // 'N/A';
		my $size = $data{'finalsz'} // 'N/A';
		my $duration = $data{'finald'} // 'N/A';
		my $error = $data{'fr'} // 'N/A';
		my $deleted = 'No';
		if (exists $data{'del'}) {
			$deleted = 'Yes';
		}
	
		my $schedstarttime = 'N/A';
		if ($schedstart =~ /^\d+$/) {
			chomp($schedstarttime = `date "+%d/%m/%Y %H:%M" -d \@$schedstart` // 'N/A');
		}

		my $actstarttime = 'N/A';
		if ($actstart =~ /^\d+$/) {
			chomp($actstarttime = `date "+%d/%m/%Y %H:%M" -d \@$actstart` // 'N/A');
		}

		my $dur = 'N/A';
		if ($duration =~ /^\d+$/) {
			my $thing = "\@" . $duration;
			chomp($dur = `date "+%H:%M:%S" -u -d $thing` // 'N/A');			
		}

print <<INFO;
Item Details:
Item ID = $pvrid
Title = $title
Channel Name = $channame
Channel Number = $channo
Source = $src
Scheduled Start Time = $schedstarttime
Actual Start Time = $actstarttime
Status = $status
Error (If Applicable) = $error
Size (in Kb) = $size
Duration (hh:mm:ss) = $dur
Deleted = $deleted

INFO

		if ($error =~ /^Failed/i) {
			if ($delfailed) {
				my $deleteurl = 'http://' . $$ip . ":$skyqport/as/pvr/action/delete?pvrid=$pvrid";
				getURL($deleteurl);
			}
		}
	}
}

sub searchSkyPlus {
	my ($ip,$xml) = @_;
	my $browseurl;
	my $serial;
	my $model;
	my $software;

	if ($$xml =~ m/\<modelName\>(.+)\<\/modelName\>/) {
		$model = $1;
		if ($model !~ /\++/) {
			print "STB at $$ip is not a PVR. Skipping it\n";
			return;
		}
	}

	if ($$xml =~ m/\<modelNumber\>(.+)\<\/modelNumber\>/) {
		$software = $1;
	}
	
	if ($$xml =~ m/\<controlURL\>(.+SkyBrowse)\<\/controlURL\>/) {
		$browseurl = $1;
	} else {
		print "ERROR: No SkyBrowse URL found for STB at $$ip\n";
		return;
	}

	if ($$xml =~ m/\<friendlyName\>(.+)<\/friendlyName\>/) {
		$serial = $1;
	} else {
		print "ERROR: Could not get serial number from STB at $$ip\n";
	}
	
	my $pvrfile = $plannerdir . $serial . '-plannerContents.txt';
	my $pvrfh;
	if (!open $pvrfh, '+>', $pvrfile) {
		print "ERROR: Unable to open $pvrfile: $!\n";
		return;
	}
	select $pvrfh;
	print "---------- Sky+ STB found at $$ip ----------\n";

print <<STBDATA;
STB Type = $model
Serial = $serial
Software = $software

STBDATA

	my $start = '0';
	my $end = '0';
	my $objid = '0';
	my $stuff = getSkyPlusXML($ip,\$browseurl,\$objid,\$start,\$end);

	my @containers = split('<container',$$stuff);
	my %conts;
	foreach my $cont (@containers) {
		if ($cont =~ /id="(\d+)" parentID="(\d+)" restricted="0" searchable="1"><dc:title>(\w+)<\/dc:title>/) {
			%{$conts{$3}} = ( 'ID' => $1, 'ParentID' => $2);
		}
	}
	
	my $total = '1';
	$end = '25';
	my $matches = '0';
	my $searchcont;
	if (!exists $conts{'pvr'}{'ID'}) {
		print "ERROR: No pvr container found on the STB\n";
		return;
	} else {
		$searchcont = $conts{'pvr'}{'ID'};
	}
	
	my $fail;
	until ($start > $matches or $fail) {
		my $pdata = getSkyPlusXML($ip,\$browseurl,\$searchcont,\$start,\$end);
		if ($$pdata =~ /Error/i) {
			$fail = 1;
		}

		if (!$matches) {
			if ($$pdata =~ m/\<TotalMatches\>(\d+)\<\/TotalMatches\>/) {
				$matches = $1;
			}
		}
		
		my $processed = processContent($pdata,$ip,\$browseurl);
		if ($processed) {
			print $$processed . "\n\n" if (ref($processed) eq 'SCALAR');
		}
		
		$start = $end;
		$end = '25'+$end;
	}
}

sub getSkyPlusXML {
	my ($ip,$browseurl,$objectid,$start,$end) = @_;
	my $ua = new LWP::UserAgent;
	my $service = "http://$$ip\:$skyplusport$$browseurl";
	$ua->agent("SKY");
	$ua->timeout(5);
	my $header = new HTTP::Headers (
				'Content-Type' => 'text/xml; charset="utf-8"',
				'SOAPAction' => '"urn:schemas-nds-com:service:SkyBrowse:2\#Browse"',
			);

my $content = <<CONTENT;
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/" xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
<s:Body>
<u:Browse xmlns:u="urn:schemas-nds-com:service:SkyBrowse:2">
<ObjectID>$$objectid</ObjectID>
<BrowseFlag>BrowseDirectChildren</BrowseFlag>
<Filter>*</Filter>
<StartingIndex>$$start</StartingIndex>
<RequestedCount>$$end</RequestedCount>
<SortCriteria/>
</u:Browse>
</s:Body>
</s:Envelope>
CONTENT

	my $request = new HTTP::Request('POST',$service,$header,$content);
	my $response = $ua->request($request);
	my $stuff = $response->content;
	if (!$response->is_success) {
		$stuff = "ERROR:\n" . $stuff;
	}
	$stuff =~ s/\&amp\;/\&/g;
	$stuff =~ s/\&lt\;/\</g;
	$stuff =~ s/\&gt\;/\>/g;
	$stuff =~ s/\&quot\;/\"/g;
	$stuff =~ s/\&apos\;/\'/g;
	return \$stuff;
}

sub processContent {
	use XML::Hash;
	my ($data,$ip,$browseurl) = @_;
	my @parts = split('item id=',$$data);
	my $string;
	my %data;
	foreach my $part (@parts) {
		if ($part =~ m/BOOK:(\d+)/) {
			$part = '<item id=' . $part;
		} else {
			next;
		}
		$part =~ s/\<$//;
		$part =~ s/upnp:|vx:|dc://g;
		$part =~ s/\n|\r//g;
		$part =~ s/(\<\/item\>).+/$1/m;

		my $xh = XML::Hash->new();
		my $xmlhash = $xh->fromXMLStringtoHash($part);
		my %info = %{$$xmlhash{'item'}};
		my %formatted;
		while (my ($key, $val) = each %info) {
			if (defined $val and $val =~ /\S+/) {
				if (ref($val) eq 'HASH') {
					if (exists $$val{'text'}) {
						$formatted{$key} = $$val{'text'};
					} else {
						$formatted{$key} = 'N/A';
					}
				} else {
					$formatted{$key} = $val;
				}
			} else {
				$formatted{$key} = 'N/A';
			}
		}

		##### Work out what part of the disk the item is assigned to (user/system/recycle)
		my $disksection = 'N/A';
		if ( exists $formatted{'X_bookingDiskQuotaName'}) {
			$disksection = $formatted{'X_bookingDiskQuotaName'} // 'N/A';
		}

		##### Work out item type
		my %types = ('1' => 'Time Based Booking', '2' => 'EPG Recording', '3' => 'On Demand Download');
		my $type = $formatted{'X_baseType'} // '';
		if ($type) {
			$type = $types{$type} // 'N/A';
		} else {
			$type = 'N/A';
		}
		
		##### Work out time and date
		my $schedstart = 'N/A';
		my $actstart = 'N/A';
		if (exists $formatted{'scheduledStartTime'}) {
			$schedstart = $formatted{'scheduledStartTime'};
			$schedstart =~ s/T/ /g;
			$schedstart =~ s/\+\S+$//;
			$schedstart =~ s/(\d+)-(\d+)-(\d+)/$3\/$2\/$1/;
			$schedstart =~ s/(\d+):(\d+):(\d+)/$1:$2/;
		}
		if (exists $formatted{'recordedStartDateTime'}) {
			$actstart = $formatted{'recordedStartDateTime'};
			$actstart =~ s/T/ /g;
			$actstart =~ s/\+\S+$//;
			$actstart =~ s/(\d+)-(\d+)-(\d+)/$3\/$2\/$1/;
			$actstart =~ s/(\d+):(\d+):(\d+)/$1:$2/;
		}
		
		
		##### Work out content status
		my $status = 'N/A';
		if (exists $formatted{'X_pdlDownloadStatus'} and $formatted{'X_pdlDownloadStatus'} != 0) {
			my %pdlstats = ('0' => 'Not Applicable', '1' => 'Scheduled', '2' => 'Starting', '3' => 'Downloading', '4' => 'Stopping', '5' => 'Complete');
			$status = $pdlstats{$formatted{'X_pdlDownloadStatus'}};
		} 
		if (exists $formatted{'X_recStatus'} and $formatted{'X_recStatus'} != 0) {
			my %recstats = ( '0' => 'N/A (PDL Booking)', '1' => 'Recording Scheduled', '2' => 'Starting to record', '3' => 'Currently Recording',
			                  '4' => 'Stopping Recording', '5' => 'Recording Finished', '6' => 'Status Undetermined, box is not fully initialised' );
			$status = $recstats{$formatted{'X_recStatus'}};
		}
		
		my $contentstate = 'N/A';
		if ($part =~ m/contentStatus=\"(\d+)\"/) {
			my %contstatemsgs = ('1' => 'No Content', '2' => 'Partial Content', '3' => 'All Content', '4' => 'Unknown');
			$contentstate = $contstatemsgs{$1} if (exists $contstatemsgs{$1});
		}
		
		##### Work out the error message if applicable
		my $error = 'N/A';
		if ($status =~ /Finished|Complete/ and $contentstate ne 'All Content') {
			if ($part =~ /failed=\"1\"/) {
				$error = 'Failed Recording';
				##### Delete this recording if $delfailed is defined
				if ($delfailed) {
					deleteFailedSkyPlus($ip,$browseurl,\$formatted{'id'});
				}
			} elsif ($contentstate eq 'Partial Content') {
				$error = 'Part Recording';
			} else {
				$error = 'Error Unknown';
			}
			my $errortext = 'N/A';
			if ($part =~ /exception=\"(\d+)\"/) {
				my $errcode = $1;
				if (exists $exceptions{$errcode}) {
					$errortext = $exceptions{$errcode};
				}
			}
			$error .= ' - ' . $errortext;
		}

		##### Work out item size
		my $kb = '0';
		if ($part =~ m/size=\"(\d+)\"/) {
			my $bytes = $1;
			$kb = sprintf("%.0f",$bytes / 1024);
		}
		
		##### Get and format the duration
		my $duration = 'N/A';
		if (exists $formatted{'recordedDuration'}) {
			$duration = $formatted{'recordedDuration'};
			($duration) = $duration =~ /(\d{1,2}\:\d{1,2}\:\d{1,2})/;
		}

		##### Check channel number
		my $channum = 'N/A';
		if (exists $formatted{'channelNr'}) {
			$channum = $formatted{'channelNr'};
			if ($channum =~ /65535/) {
				$channum = 'PVOD';
			}
		}

$string .= <<RECINFO;
Item Details:
Item ID = $formatted{'id'}
HDD Location = $disksection
Title = $formatted{'title'}
Channel Name = $formatted{'channelName'}
Channel Number = $channum
Source = $type
Scheduled Start Time = $schedstart
Actual Start Time = $actstart
Status = $status
Content State = $contentstate
Error (If Applicable) = $error
Size (in Kb) = $kb
Duration (hh:mm:ss) = $duration

RECINFO
	}
	return \$string;
}

sub checkReqs {
	chomp(my $installed = `which gssdp-discover` // '');
	if (!$installed) {
		die "You do not appear to have gssdp-discover (part of the gupnp-tools package) installed on your system. Please install it via \'apt-get install gupnp-tools\' and try again\n";
	}
	chomp(my $wget = `which wget` // '');
	if (!$wget) {
		die "You do not appear to have wget installed on your system. Please install it via \'apt-get install wget\' and try again\n";
	}
}

sub parseInfoJSON {
	my ($in) = @_;
	my $json = JSON->new->allow_nonref;
	my $decoded = $json->pretty->decode($$in);
	my %hash = %{$decoded};
	my ($serial,$sw,$hw) = ('N/A','N/A','N/A');
	my %hwnames = ( 'X-Wing' => 'Sky Q', 'Falcon' => 'Sky Q Silver');

	if (exists $hash{'modelNumber'}) { $sw = $hash{'modelNumber'} };
	if (exists $hash{'serialNumber'}) { $serial = $hash{'serialNumber'} };
	if (exists $hash{'hardwareName'}) { 
		my $nameraw = $hash{'hardwareName'};
		$hw = $hwnames{$nameraw};
	};

	##### Format the serial number to 9 digits without preceding 0
	if ($serial ne 'N/A') {
		$serial =~ s/^0//;
		$serial =~ s/\s+//g;
		($serial) = $serial =~ /^(\d{9})/;
	}
	my $string = "STB Type = $hw\nSerial = $serial\nSoftware = $sw\n";
	return \$string;
}

sub loadSkyPlusExceptions {
	my $excodesraw = `cat $exceptionfile` // '';
	my @codes = split("\n",$excodesraw);
	my %exceps;
	foreach my $coderaw (@codes) {
		chomp $coderaw;
		my ($num,$text) = $coderaw =~ /(\S+)\-\-\>(\S+)/;
		$exceps{$num} = $text;
	}
	return %exceps;
}

sub getURL {
	my ($url,$useragent) = @_;
	my $ua = new LWP::UserAgent;
	if ($useragent) {
		$ua->agent($useragent);
	}
	$ua->timeout(5);
	my $request = new HTTP::Request('GET',$url);
	my $response = $ua->request($request);
	my $stuff = $response->content;
	if (!$response->is_success) {
		$stuff = "ERROR:\n" . $stuff;
	}
	return $stuff;
}

sub deleteFailedSkyPlus {
	my ($ip,$browseurl,$bookid) = @_;
	my $ua = new LWP::UserAgent;
	my $port = '41653';
	my $service = "http://$$ip\:$port$$browseurl";
	$ua->agent("SKY");
	
	my $header = new HTTP::Headers (
	'Content-Type'  => 'text/xml; charset="utf-8"',
	'SOAPAction'    => '"urn:schemas-nds-com:service:SkyBrowse:2\#DestroyObject"',
	);
	
	
my $content = <<CONTENT;
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/" xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
<s:Body>
<u:DestroyObject xmlns:u="urn:schemas-nds-com:service:SkyBrowse:2">
<ObjectID>$$bookid</ObjectID>
</u:DestroyObject>
</s:Body>
</s:Envelope>
CONTENT
	
	my $request = new HTTP::Request('POST',$service,$header,$content);
	my $response = $ua->request($request);
}

sub printHelp {
print <<HELP;
********* Sky STB Planner Trawler *********
Version 1.1
Author: Christopher Get
Contact: Christopher.get\@sky.uk

This tool has been designed to trawl the local network for Sky+ and SkyQ STBs
and save a textual representation of their planner contents in seperate
files organised by the STB serial number.

The input options are listed below:
Key: 	(flag) = Just provide the option
	<text> = Option requires text parameter (NOT including <> characters)

 --help				# Displays this help text. Any other input arguments are ignored
 --interface	<name>		# The local network interface to use for the search
 --search_time	<time>		# The time in seconds to wait for UPnP responses from STBs
 --results_directory <path>	# Specify a directory to store the results in. Default is 'stbPlannerFiles' within the main directory
 --stb_types	<type>		# Use this option to specify which type of STB to look for. Valid options are:
 					"Sky+" -> Only analyse Sky+ STBs
 					"SkyQ" -> Only analyse SkyQ STBs
 					"SkyQSilver" -> Only analyse SkyQSilver STBs
	 			# (Options are case insensitive. If no VALID option is provided then BOTH types are analysed)
				# Multiple options can be selected by separating them with a comma e.g,
					--stb_types "SkyQ,SkyQSilver"
				
 --delete_failed		# Delete failed recordings as they are discovered. These will still be reported on when they are
 				# discovered but will not then show up in subsequent searches
 --clear_previous (flag)	# Clear out stb data files from previous runs
 --quiet (flag)			# Suppress info messages from printing to STDOUT (Error messages will still print out)
HELP
}
