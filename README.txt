********* Sky STB Planner Trawler *********
Version 1.1
Author: Christopher Get
Contact: Christopher.get\@sky.uk

This tool is designed to extract the contents of a Sky PVR STB and store a textual
representation of the content within text files.
This will work with Sky+ HD (DRX890 and newer), Sky Q 1TB, and Sky Q Silver 2TB.

######### Pre-requisites #########
  OS:
    - Linux. Debian 8 or higher preferred.
  
  Installed Programs:
    - perl
    - wget
    - gupnp-tools (which contains the 'gssdp-discover' utility)
    - libcpan-meta-perl ('cpan' utility for installing perl modules)
    
    -- Handy install line to copy and paste on to the command line:
     apt-get install -y perl wget gupnp-tools libcpan-meta-perl
    
  Perl modules (Installed via cpan):
    - JSON
    - HTTP::Request::Common
    - LWP::UserAgent
    - Cwd
    - Getopt::Long
    - XML::Hash
    
    -- Handy install line to copy and paste in to the CPAN shell:
     install JSON HTTP::Request::Common LWP::UserAgent Cwd Getopt::Long XML::Hash

######### Getting started #########
  On the command line, run the following:
    perl skyPlannerTrawler.pl --help
  
  The help command will display all available input options. The minimum required input 
  is to define an interface to search on for Sky STBs e,g:
    perl skyPlannerTrawler.pl --interface eth0
