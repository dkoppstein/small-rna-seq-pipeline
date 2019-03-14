#!/usr/bin/perl
use warnings;
use strict;
use Getopt::Long;
use File::Basename;

my $version_num = "3.8.5";
my $usage_message = usage_message($version_num);
my $command_line = join(" ", @ARGV);

###### Get ye options ###############
my %options = get_ShortStack_options($version_num);


##########  Version or Help  Requested ? #########
# version ... just print version to STDOUT
if(exists($options{'version'})) {
    print "ShortStack version $version_num\n";
    exit;
}

# help ... print longer help message #
if(exists($options{'help'})) {
    help_message($version_num);
    exit;
}

# If there are any extraneous arguments, quit and complain
if($ARGV[0]) {
    die "\nUnknown arguments: @ARGV\n$usage_message";
}

######## Input file_path validations ########
validate_genome(\%options,\$usage_message);

if(exists($options{'bamfile'})) {
    validate_bamfile1(\%options,\$usage_message);
}

if(exists($options{'cramfile'})) {
    validate_cramfile1(\%options,\$usage_message);
}

if(exists($options{'readfile'})) {
    validate_readfile1(\%options,\$usage_message);
}

if(exists($options{'locifile'})) {
    unless(-r $options{'locifile'}) {
	die "\ncountfile $options{'locifile'} is not readable\n\n$usage_message\n";
    }
    if($options{'locus'}) {
	die "\noptions --locus and --locifile are mutually exclusive\n\n$usage_message\n";
    }
}

if(exists($options{'cquals'})) {
    validate_cquals(\%options,\$usage_message);
}

if(exists($options{'total_primaries'})) {
    validate_total_primaries(\%options,\$usage_message);
}

######### check for invalid combinations of input file_paths
if((${$options{'readfile'}}[0]) and
   ((exists($options{'bamfile'})) or (exists($options{'cramfile'})))) {
    die "Invalid option combination: readfile is mutually exclusive with bamfile and/or cramfile\n\n$usage_message\n";
}

if((exists($options{'bamfile'})) and (exists($options{'cramfile'}))) {
    die "Invalid option combination: bamfile is mutually exclusive with cramfile\n\n$usage_message\n";
}

if(((exists($options{'bamfile'})) or (exists($options{'cramfile'}))) and
   (exists($options{'align_only'}))) {
    die "Invalid option combination: align_only can't be specified if a bamfile or cramfile is provided\n\n$usage_message\n";
}
if(exists($options{'total_primaries'})) {
    unless((exists($options{'bamfile'})) or (exists($options{'cramfile'}))) {
	die "Invalid option combination: The option total_primaries can only be used in conjunction with bamfile or cramfile\n\n$usage_message\n";
    }
}

######### Validate the other options #####
validate_outdir(\%options,\$usage_message);
my @adapters = validate_adapter(\%options,\$usage_message);
validate_bowtie_cores(\%options,\$usage_message);
validate_mismatches(\%options,\$usage_message);
validate_dicerminmax(\%options,\$usage_message);
validate_pad(\%options,\$usage_message);
validate_mmap(\%options,\$usage_message);
validate_mincov(\%options,\$usage_message);
validate_bowtie_m(\%options,\$usage_message);
validate_ranmax(\%options,\$usage_message);
validate_locus(\%options,\$usage_message);
validate_sort_mem(\%options,\$usage_message);
validate_foldsize(\%options,\$usage_message);
validate_strand_cutoff(\%options,\$usage_message);

## Requesting a mincov in units of rpmm is incompatible with specifying an explicit 'total_primaries'
if((exists($options{'total_primaries'})) and
    ($options{'mincov'} =~ /rpmm$/)) {
    die "Option total_primaries cannot be used in combination with a setting of option mincov in units of rpmm. Use units of rpm or raw reads instead.\n";
}

######## Check for required dependencies
my $samtools_which = install_check('samtools',$usage_message);
my $samtools_version = samtools_version1_check($usage_message);
my $bowtie_which;
my $gzip_which;
if(${$options{'readfile'}}[0]) {
### if(exists($options{'readfile'})) {
    $bowtie_which = install_check('bowtie', $usage_message);
    $gzip_which = install_check('gzip',$usage_message);
}
my $RNAfold_which;
unless($options{'nohp'}) {
    $RNAfold_which = install_check('RNAfold',$usage_message);
    $options{'RNAfold_version'} = check_RNAfold_version();
}
###### Initiate log file ########
initiate_log(\%options, \$version_num);

###### Genome processing

# check for fai file
my $fai_file = fai(\%options);
my $stitch_fai_file;
# genome stitching, if warranted
unless((exists($options{'align_only'})) or (exists($options{'nohp'})) or (exists($options{'locus'}))) {
    my $need2 = need_to_stitch(\%options);  ## $need2 is the size of N's to be added when stitching. As of 3.8, always 100 (or 0)
    if($need2) {
	$stitch_fai_file = stitch_genome(\%options,\$need2);
	$options{'stitchfai_file'} = $stitch_fai_file;
    }
}
# Add final genome .fai file to the options hash, for convenience later
$options{'fai_file'} = $fai_file;

# check and build .ebwt (or ebwtl) indices, if warranted
my $g_type;
if(exists($options{'readfile'})) {
    $g_type = ebwt(\%options);  ## g_type is either 's' or 'l' for small or large genomes, resp.
    $options{'g_type'} = $g_type;
}

# trim 3' adapters, if warranted
my @t_readfiles = ();
if((@adapters) and (exists($options{'readfile'}))) {
    @t_readfiles = trim_master(\%options,\@adapters);
} elsif (exists($options{'readfile'})) {
    @t_readfiles = @{$options{'readfile'}};
}

# align, if warranted
if(@t_readfiles) {
    # If aligning, and indices are the large type, --mismatches must be set to 0 to
    #  avoid bad bowtie bug
    if(($options{'mismatches'} != 0 ) and
       ($g_type eq 'l')) {
	$options{'mismatches'} = 0;
	log_it($options{'logfile'}, "\n\*\*\* WARNING: mismatches is being set to 0 to work around a bad bowtie bug specific to large genomes \*\*\*");
    }

    align_master(\%options,\@t_readfiles,\$version_num,\$command_line);
    # After this, options{'bamfile'} or options{'cramfile'} will be set.
    # Also, $options{'total_primaries'} and $options{'total_primaries_placed'}
    # Abort if align_only was specified
    if((exists($options{'align_only'}))) {
	log_it($options{'logfile'}, "\nRun was set to align_only - terminating");
	my $ao_time = `date`;
	log_it($options{'logfile'}, "Completed at $ao_time");
	exit;
    }
}
# count the number of primary alignments, if it's not done already
# This will be the base in a countmode analysis where the user didn't state --total_primaries explicitly on the command line.
unless(exists($options{'total_primaries'})) {
    get_total_primaries(\%options);  ## also sets options{'total_primaries_placed'}
}

# analyze
if(($options{'locifile'}) or ($options{'locus'})) {
    ensure_aln_idx(\%options);
    countmode(\%options);
} else {
    denovo(\%options);
}

# summarize
summarize(\%options);

# clean up stitched file, if warranted
if(exists($options{'stitchgenomefile'})) {
    system "rm -f $options{'stitchgenomefile'}";
}
if(exists($options{'stitchfai_file'})) {
    system "rm -f $options{'stitchfai_file'}";
}

exit;

#############################################################
# Here be sub-routines #

sub usage_message {
    my $version = shift;
    my $usage_message = "\nShortStack version $version
Usage: ShortStack [options] {--readfile <r> | {--bamfile <b> | --cramfile <c>}} --genomefile <g>

<r> : readfile must be in fasta (.fasta or .fa), colorspace-fasta (.csfasta),
      or fastq (.fastq or .fq) format, or their gzip-compressed versions
      (.fasta.gz, .fa.gz, .csfasta.gz, .fastq.gz, or .fq.gz)
      Can also be a list (seperated by spaces) of several read files.
<b> : BAM formatted alignment file (.bam).
<c> : CRAM formatted alignment file (.cram).
<g> : FASTA formatted (.fa or .fasta) genome file.

Dependencies (in PATH):

samtools (version 1.x)
bowtie (if aligning)
bowtie-build (if aligning and .ebwt indices not found)
gzip (if aligning)
RNAfold (unless running with --nohp option to disable MIRNA search)

Type ShortStack --help for full option list
Type perldoc ShortStack for documentation, or see README
";
    return $usage_message;
}

sub help_message {
    my($version_num) = @_;
    print "\nShortStack version $version_num
Usage: ShortStack [options] {--readfile <r> | {--bamfile <b> | --cramfile <c>}} --genomefile <g>

<r> : readfile must be in fasta (.fasta or .fa), colorspace-fasta (.csfasta),
      or fastq (.fastq or .fq) format, or their gzip-compressed versions
      (.fasta.gz, .fa.gz, .csfasta.gz, .fastq.gz, or .fq.gz)
      Can also be a list (seperated by spaces) of several read files.
<b> : BAM formatted alignment file (.bam).
<c> : CRAM formatted alignment file (.cram).
<g> : FASTA formatted (.fa or .fasta) genome file.

Dependencies (in PATH):

samtools (version 1.x)
bowtie (if aligning)
bowtie-build (if aligning and .ebwt indices not found)
gzip (if aligning)
RNAfold (unless running with --nohp option to disable MIRNA search)

General Options:

--help : print this message and quit

--version : print version and quit

--genomefile [string] : path to reference genome in .fasta or .fa format. Required for any run.

--outdir [string] : name of output directory to be created for results. Defaults to 'ShortStack_[time]',
  where [time] is the current UNIX time according to the system. If the outdir already exists, ShortStack
  will exit with an error message.

Alignment Options:

--readfile [string] : path to readfile(s) to be aligned. valid formats: .fasta, .fa, .fasta.gz,
  .fa.gz, .fastq, .fq, .fastq.gz, .fq.gz, .csfasta, .csfasta.gz. Multiple files, can be specified as
  separate arguments to --readfile ... e.g. --readfile file1.fastq file2.fastq file3.fastq
  Mutually exclusive with --bamfile or --cramfile.

--adapter [string] : sequence of 3' adapter to trim off during read-pre processing. Must be at least
  8 bases, with only ATCG characters. If not specified, reads are assumed to be already trimmed.

--bowtie_cores [integer] : Argument to be passed to bowtie's -p option, specifying number of processor
  cores to request during alignment. Defaults to 1. Must be an integer of 1 or more.

--sort_mem [string] : Argument to be passed to samtools sort -m option, which sets the maximum memory
  usage during bam file sorting. If not set, samtools sort defaults it to 768M. Higher settings will
  reduce the overall time spent in alignment phase, at cost of more memory usage. Use K/M/G suffixes to
  specify kilobytes, megabytes, and gigabytes, respectively. Extremely large alignment jobs will
  crash (due to crash of samtools sort operation) if --sort_mem is not set high enough. However, alignment
  jobs will also crash if sort_mem is set too high, and all physical memory on your machine is exahusted.

--mismatches [integer] : Argument to be passed to bowtie's -v option, specifying number of mismatches
  to be tolerated in a valid alignment. Must be either 0, 1, or 2. In cases of multiple hits, only hits
  with lowest number of mismatches kept. Default: 1.

--cquals [string] : path(s) to color-space quality value file(s). Used only in conjunction with .csfasta
  or .csfasta.gz formatted files in --readfile. Compressed format for cquals is NOT allowed. Like --readfile,
  cquals can take multiple arguments for multiple files, e.g. --cquals file1.qual file2.qual file3.qual

--cram : When aligning, convert final alignment to cram format instead of the default bam format.

--mmap [string] : Protocol for handling multi-mapped reads. Valid entries are n (none), r (random), u (unique-
  seeded guide), or f (fractional-seeded guide). default: u

--bowtie_m [string] : Setting to be passed to the -m option of bowtie. Over-ridden and set to 1 if option
  mmap is set to n. This sets the maximum number of multi-mappings allowed. Valid settings are integers >= 1 OR set 'all'
  to disable suppression of highly multi-mapped reads. Default: 50

--ranmax [string] : Reads with more than this number of possible alignment positions where the
  choice can't be guided by unequal  will be reported as unmapped. Irrelevant if option mmap is set
  to n or r. Must be integer of 2 or greater or set to 'none' to disable. Default: 3.

--align_only : If this switch is present, the ShortStack run will terminate after the alignment phase
  with no analysis performed.

--show_secondaries : If this switch is present, the output alignment file will contain secondary alignments
  as well as primary alignments for multi-mapped reads. Secondary alignments have bit 256 set in the SAM FLAG field.
  This option can increase alignment file size, sometimes by a lot.

--keep_quals : As of version 3.5, by default ShortStack alignments no longer store the quality values, to save space. Use
  of this switch will cause quality values to be retained. Note that this increases file size.

Analysis Options:

--bamfile [string] : path to input .bam alignment file of small RNAs. Only lines with bits 4 and 256
  unset will be used. Mutually exclusive with --readfile or --cramfile.

--cramfile [string] : path to input .cram alignment file of small RNAs. Only lines with bits 4 and 256
  unset will be used. Mutually exclusive with --readfile or --bamfile.

--dicermin [integer] : Minimum size of a Dicer-processed small RNA. Must be an integer of at least 15
  and <= dicermax. Default: 20.

--dicermax [integer] : Maximum size of a Dicer-processed small RNA. Must be an integer of at least 15
  and >= dicermin. Deafult: 24.

--foldsize [integer] : Size of genomic RNA segments for folding during MIRNA search. Any loci larger
  than this size will not be analyzed with respect for MIRNA features. Must be an integer of at
  least 200 and no larger than 1,000. Default: 300. Note that increasing this setting may drastically
  increase runtimes.

--locifile [string] : Path to a tab-delimited plain-text file listing intervals to analyze. Lines
  starting with # are ignored. First column is coordinate in format Chr:start-stop, second column
  is names (optional), and any other columns are ignored. Mutually exclusive with option --locus.

--locus [string] : Analyze the specified interval(s). Interval(s) is specified in format Chr:start-stop.
  Multiple intervals can be specified in a comma-separated list. Mutually exclusive with option
  --locifile. Specify the value for --total_primaries to make a single locus run fast.

--nohp : Disable MIRNA search.

--pad [integer] : Initially found clusters of small RNAs will be merged if the distance between them is
  less than or equal to the value of pad. Must be an integer between 0 and 50000. Default: 75.

--mincov [string] : Clusters of small RNAs must have at least this many alignments. Supply an
  integer between 1 and 50000. Can also be a normalized value in reads per million (rpm) OR reads per million mapped (rpmm). When specifying mincov in
  rpm or rpmm, the mincov value must be a floating point number > 0 and < 500,000 followed
  by the string 'rpm' or 'rpmm'. Examples: '5' --> threshold is 5 raw reads. '3.2rpm' --> threshold is
  3.2 reads per million mapped. '2.8rpmm' --> threshold is 2.8 reads per million mapped. Deafult: 0.5rpm.

--strand_cutoff [float] : Cutoff for calling the strandedness of a locus. Must be a floating point number
  between 0.5 and 1 (inclusive). DEFAULT: 0.8. At default of 0.8, a locus must have 80% of more of its
  reads on the top strand to be called a + strand locus, or 20% or less on the top strand to be a -
  strand locus. All others receive no strand call (e.g. '.'). Only stranded loci are analyzed for
  MIRNAs, while only unstranded loci are analyzed with respect to phasing. Most users probably want
  to use the default setting of 0.8.

--total_primaries [integer] : Tell ShortStack the total number of primary alignments in the bam file. Specifying
  this value here speeds the analysis, since ShortStack does not need to count the reads directly from the bam file.
  Can only be specified in conjunction with --bamfile. This count should include all primary alignment INCLUDING unplaced ones.

Type perldoc ShortStack for documentation, or see README

";

}

sub get_ShortStack_options {
    ## Uses GetOptions from Getopt::Long to store options in a hash
    ##  also sets the defaults for options that have a default.
    ##  the version number of ShortStack is passed by value
    my($v_num) = shift;
    my %options = ();
    GetOptions(\%options,
	       'help',
	       'version',
	       'readfile=s@{,}',
	       'bamfile=s',
	       'cramfile=s',
	       'genomefile=s',
	       'outdir=s',
	       'adapter=s',
	       'bowtie_cores=i',
	       'mismatches=i',
	       'dicermin=i',
	       'dicermax=i',
	       'locifile=s',
	       'locus=s',
	       'nohp',
	       'pad=i',
	       'mincov=s',
	       'cquals=s@{,}',
	       'cram',
	       'mmap=s',
	       'bowtie_m=s',
	       'ranmax=s',
	       'align_only',
	       'sort_mem=s',
	       'foldsize=i',
	       'show_secondaries',
	       'keep_quals',
	       'total_primaries=i',
	       'strand_cutoff=f'
	);

    # If no options were passed, just print help and walk away
    unless(%options) {
	my $usage_message = usage_message($version_num);
	die "$usage_message\n";
    }
    return %options;
}

sub validate_total_primaries {
    my($options,$usage) = @_;
    if(exists($$options{'total_primaries'})) {
	unless($$options{'total_primaries'} =~ /^\d+$/) {
	    die "\nentry for option --total_primaries is invalid. Must be an integer of 1 or more.\n\n$$usage\n";
	}
	unless($$options{'total_primaries'} >= 1) {
	    die "\nentry for option --total_primaries is invalid. Must be an integer of 1 or more.\n\n$$usage\n";
	}
    }
}

sub validate_locus {
    my($options,$usage) = @_; ## references to hash, scalar
    if(exists($$options{'locus'})) {
	my @entries = split (',', $$options{'locus'});
	foreach my $entry (@entries) {
	    unless($entry =~ /^(\S+):(\d+)-(\d+)$/) {
		die "\nentry $entry for option --locus is invalid. Must be in format Chr:Start-Stop\n\n$$usage\n";
	    }
	}
    }
}

sub validate_foldsize {
    my($options,$usage) = @_; ## references to hash, scalar
    if((exists($$options{'nohp'})) or (exists($$options{'align_only'}))) {
	if(exists($$options{'foldsize'})) {
	    delete $$options{'foldsize'};
	}
    } elsif (exists($$options{'foldsize'})) {
	# must be an integer
	unless($$options{'foldsize'} =~ /^\d+$/) {
	    die "\noption foldsize is invalid. Must be an integer between 200 and 1000\n\n$$usage\n";
	}
	# must be >= 200 and <= 1000
	unless(($$options{'foldsize'} >= 200) and ($$options{'foldsize'} <= 1000)) {
	    die "\noption foldsize is invalid. Must be an integer between 200 and 1000\n\n$$usage\n";
	}
    } else {
	# default is 300
	$$options{'foldsize'} = 300;
    }
}

sub validate_outdir {
    ## Takes in the outdir, and checks to see if it exists.
    ##  if it alread exists, abort program
    ##  input is a reference to the options hash and a reference to the usage message
    my($options,$usage) = @_;
    if(exists($$options{'outdir'})) {
	# if user added a trailing / , remove it
	if($$options{'outdir'} =~ /\/$/) {
	    $$options{'outdir'} =~ s/\/$//;
	}

    } else {
	## generate the name for the outdir
	my $t = time;
	my $od = "ShortStack" . "_$t";
	$$options{'outdir'} = $od;
    }

    if(-e $$options{'outdir'}) {
	die "\noutdir $$options{'outdir'} already exists\n\n$usage\n";
    }
}

sub initiate_log {
    ## takes in reference to the options hash, and reference to version number
    ##  and begins writing the log file for the run
    ## also creates the output directory
    my($options,$v_num) = @_;

    system "mkdir -p $$options{'outdir'}";

    my $logfile = "$$options{'outdir'}" . '/' . 'Log.txt';
    my $error_logfile = "$$options{'outdir'}" . '/' . 'ErrorLogs.txt';

    $$options{'logfile'} = $logfile;
    $$options{'error_logfile'} = $error_logfile;

    log_it($logfile, "\nShortStack version $$v_num");
    my $date = `date`;
    chomp $date;
    log_it($logfile, "$date");
    my $host = `hostname`;
    chomp $host;
    log_it($logfile, "hostname: $host");
    my $wd = `pwd`;
    chomp $wd;
    log_it($logfile, "working directory: $wd");
    log_it($logfile, "\nSettings:");

    # Clear irrelevant options, as warranted
    if(($$options{'bamfile'}) or ($$options{'cramfile'})) {
	# Clear all alignment related options
	if(exists($$options{'readfile'})) {
	    delete $$options{'readfile'};
	}
	if(exists($$options{'adapter'})) {
	    delete $$options{'adapter'};
	}
	if(exists($$options{'bowtie_cores'})) {
	    delete $$options{'bowtie_cores'};
	}
	if(exists($$options{'mismatches'})) {
	    delete $$options{'mismatches'};
	}
	if(exists($$options{'cquals'})) {
	    delete $$options{'cquals'};
	}
	if(exists($$options{'cram'})) {
	    delete $$options{'cram'};
	}
	if(exists($$options{'mmap'})) {
	    delete $$options{'mmap'};
	}
	if(exists($$options{'bowtie_m'})) {
	    delete $$options{'bowtie_m'};
	}
	if(exists($$options{'ranmax'})) {
	    delete $$options{'ranmax'};
	}
    }
    if(($$options{'locus'}) or ($$options{'locifile'})) {
	if(exists($$options{'pad'})) {
	    delete $$options{'pad'};
	}
    }
    if($$options{'align_only'}) {
	# clear all analysis options
	if(exists($$options{'dicermin'})) {
	    delete $$options{'dicermin'};
	}
	if(exists($$options{'dicermax'})) {
	    delete $$options{'dicermax'};
	}
	if(exists($$options{'locifile'})) {
	    delete $$options{'locifile'};
	}
	if(exists($$options{'locus'})) {
	    delete $$options{'locus'};
	}
	if(exists($$options{'nohp'})) {
	    delete $$options{'nohp'};
	}
	if(exists($$options{'pad'})) {
	    delete $$options{'pad'};
	}
	if(exists($$options{'mincov'})) {
	    delete $$options{'mincov'};
	}
    }

    my @opt_keys = sort ( keys %$options);
    my $report;
    foreach my $opt_name (@opt_keys) {
	if(($opt_name eq 'readfile') or
	   ($opt_name eq 'cquals')) {
	    $report = "$opt_name" . ":" . " @{$$options{$opt_name}}";
	} else {
	    $report = "$opt_name" . ":" . " $$options{$opt_name}";
	}
	log_it($logfile, "$report");
    }
    log_it($logfile, "\nRun Progress and Messages:");

    # warn about any overrides
    if(($$options{'mmap'}) and ($$options{'bowtie_m'})) {
	if(($$options{'mmap'} eq 'n') and ($$options{'bowtie_m'})) {
	    log_it($logfile, "Warning: User-provided option bowtie_m of $$options{'bowtie_m'} is irrelevant what option mmap is set to n.");
	}
    }
}

sub log_it {
    ## Writes information about the progress of the run both to STDERR and to the logfile
    ##  logfile location is passed in by value, as is the text
    ##  adds a newline after every line
    my($logfile,$text) = @_;
    print STDERR "$text\n";
    open(LOG, ">>$logfile");
    print LOG "$text\n";
    close LOG;
}

sub validate_genome {
    ## Validate the readability and file format of the user's input genome
    ##  Input is a reference to the options hash, and a reference to the usage message
    ##  method fileparse is from File::Basename
    my($options,$usage) = @_;

    # --genomefile is a required option. Quit and complain if it's absent
    unless($$options{'genomefile'}) {
	die "\nMissing required option --genomefile\n\n$$usage\n";
    }

    # --genomefile must be readable
    unless(-r $$options{'genomefile'}) {
	die "\ngenomefile $$options{'genomefile'} was not readable\n\n$$usage\n";
    }

    # check the suffix, which must end in either .fa or .fasta
    my($file,$path,$suffix) = fileparse($$options{'genomefile'}, qr/\.[^\.]+$/);
    unless(($suffix eq '.fa') or ($suffix eq '.fasta')) {
	die "\ngenomefile $$options{'genomefile'} does not have required suffix .fa or .fasta suffix found was $suffix\n\n$$usage\n";
    }
}

sub validate_bamfile1 {
    ## Validate the readability and file suffix of the input bamfile
    ## Input is a reference to  the %options hash and a reference to the usage message
    ## sub-routine assumes that $$options{'bamfile'} exists.

    my($options,$usage) = @_;

    # bamfile must be readable
    unless(-r $$options{'bamfile'}) {
	die "\nbamfile $$options{'bamfile'} is not readable\n\n$$usage\n";
    }

    # bamfile suffix must be .bam
    my($file,$path,$suffix) = fileparse($$options{'bamfile'}, qr/\.\S+$/);
    unless($suffix =~ /\.bam$/) {
	die "\nbamfile $$options{'bamfile'} does not end with required file suffix .bam\n\n$$usage\n";
    }
}

sub validate_cramfile1 {
    ## Validate the readability and file suffix of the input cramfile
    ## Input is a reference to the %options hash and a reference to the usage message
    ## sub-routine assumes that $$options{'cramfile'} exists
    ## method fileparse is from File::Basename
    my($options,$usage) = @_;

    # cramfile must be readable
    unless(-r $$options{'cramfile'}) {
	die "\ncramfile $$options{'cramfile'} was not readable\n\n$$usage\n";
    }

    # cramfile suffix must be .cram
    my($file,$path,$suffix) = fileparse($$options{'cramfile'}, qr/\.\S+$/);
    unless($suffix =~ /\.cram$/) {
	die "\ncramfile $$options{'cramfile'} does not have the required suffix .cram\n\n$$usage\n";
    }
}
sub validate_readfile1 {
    ## Validate the readability and file suffix(es) of the input readfile(s).
    ## Input is a reference to %options and a reference to the usage message
    ## method fileparse is from File::Basename
    ## It is assumed that $$options{'readfile'} exists
    ## valid file suffixes are .fa, .fasta, .fastq, .fq, .csfasta,
    ## or their .gz cousins

    my($options,$usage) = @_;

    my @files = @{$$options{'readfile'}};

    foreach my $file (@files) {
	# must be readable
	(open(FILE, "$file")) || die "\nreadfile $file was not readable\n\n$$usage\n";
	close FILE;
	# suffix check
	my($file,$path,$suffix) = fileparse($file, qr/\.\S+$/);
	unless(($suffix =~ /\.fasta$/) or
	       ($suffix =~ /\.fa$/) or
	       ($suffix =~ /\.fastq$/) or
	       ($suffix =~ /\.fq$/) or
	       ($suffix =~ /\.fasta\.gz$/) or
	       ($suffix =~ /\.fa\.gz$/) or
	       ($suffix =~ /\.fastq\.gz$/) or
	       ($suffix =~ /\.csfasta$/) or
	       ($suffix =~ /\.csfasta\.gz$/) or
	       ($suffix =~ /\.fq.gz$/)) {
	    die "\nreadfile $file does not end in a valid file suffix  suffix was $suffix file was $file path was $path \n\n$$usage\n";
	}
    }
}

sub validate_adapter {
    my($options,$usage) = @_; ## passed by reference as a hash and string
    my @adapters = ();
    if($$options{'adapter'}) {
	# Adapter is pointless unless readfile is specified
	unless(exists($$options{'readfile'})) {
	    die "option adapter cannot be specified unless option readfile is also specified\n\n$$usage\n";
	}
	@adapters = split (",", $$options{'adapter'});
	foreach my $ad (@adapters) {
	    # Adapter must be a string of ATGC characters between 8 and 20 long
	    unless($ad =~ /^[ATGC]{8,20}$/) {
		die "adapter $ad is invalid. It must be a string of ATGC characters 8-20 in length\n\n$$usage\n";
	    }
	}
	# If more than one adapter was provided, the number of adapters must match the number of readfiles
	if((scalar @adapters) > 1) {
	    unless((scalar @adapters) == (scalar @{$$options{'readfile'}})) {
		die "\nThe number of adapters provided must be either one, or match the number of read files\n\n$$usage\n";
	    }
	}
    }
    return @adapters;
}

sub validate_bowtie_cores {
    my($options,$usage) = @_;  ## references to a hash and a scalar
    if($$options{'bowtie_cores'}) {
	## option bowtie_cores is pointless if not doing an alignment
	unless(exists($$options{'readfile'})) {
	    die "option mismatches cannot be specified unless option readfile is also specified\n\n$$usage\n";
	}
	# Must be an integer
	unless($$options{'bowtie_cores'} =~ /^\d+$/) {
	    die "\noption bowtie_cores is invalid. It must be an integer of 1 or more\n\n$$usage\n";
	}
	# Must be at least 1
	unless($$options{'bowtie_cores'} >= 1) {
	    die "\noption bowtie_cores is invalid. It must be an integer of 1 or more\n\n$$usage\n";
	}
    } else {
	# default to 1
	if(exists($$options{'readfile'})) {
	    $$options{'bowtie_cores'} = 1;
	}
    }
}

sub validate_mismatches {
    my($options,$usage) = @_;  ## references to a hash and a scalar
    if(exists($$options{'mismatches'})) {
	unless(exists($$options{'readfile'})) {
	    die "option mismatches cannot be specified unless option readfile is also specified\n\n$$usage\n";
	}
	# Must be an integer
	unless($$options{'mismatches'} =~ /^\d+$/) {
	    die "\noption mismatches is invalid. It must be an integer of 0, 1, or 21\n\n$$usage\n";
	}
	# Must be 0 or 1
	unless(($$options{'mismatches'} == 0) or ($$options{'mismatches'} == 1) or ($$options{'mismatches'} == 2)) {
	    die "\noption mismatches is invalid. It must be an integer of 0, 1, or 21\n\n$$usage\n";
	}
    } elsif (exists($$options{'readfile'})) {
	# if it was unset by the user, set it to 1
	$$options{'mismatches'} = 1;
    }
}

sub validate_bowtie_m {
    my($options,$usage) = @_;  ## references to a hash and a scalar
    if(exists($$options{'bowtie_m'})) {
	unless(exists($$options{'readfile'})) {
	    die "option bowtie_m cannot be specified unless option readfile is also specified\n\n$$usage\n";
	}
	# Is it an integer?
	if($$options{'bowtie_m'} =~ /^\d+$/) {
	    unless($$options{'bowtie_m'} >= 1) {
		die "\noption bowtie_m must be either an integer of 1 or more, or the word \'all\'\n$$usage\n";
	    }
	} else {
	    unless ($$options{'bowtie_m'} eq 'all') {
		die "\noption bowtie_m must be either an integer of 1 or more, or the word \'all\'\n$$usage\n";
	    }
	}
    } elsif (exists($$options{'readfile'})) {
	# if it was unset by the user, set it to default of 50, unless mmap is set to none, in which case it is set to 1
	if($$options{'mmap'} eq 'n') {
	    $$options{'bowtie_m'} = 1;
	} else {
	    $$options{'bowtie_m'} = 50;
	}
    }
}

sub validate_strand_cutoff {
    my($options,$usage) = @_;
    if(exists($$options{'strand_cutoff'})) {
	unless(($$options{'strand_cutoff'} >= 0.5) and ($$options{'strand_cutoff'} <= 1)) {
	    die "\noption strand_cutoff must be a floating point number between 0.5 and 1 (inclusive).\n\n$$usage\n";
	}
    } else {
	$$options{'strand_cutoff'} = 0.8;
    }
}

sub validate_ranmax {
    my($options,$usage) = @_;  ## references to a hash and a scalar
    if(exists($$options{'ranmax'})) {
	unless(exists($$options{'readfile'})) {
	    die "option ranmax cannot be specified unless option readfile is also specified\n\n$$usage\n";
	}
	# Is it an integer?
	if($$options{'ranmax'} =~ /^\d+$/) {
	    unless($$options{'ranmax'} >= 2) {
		die "\noption ranmax must be either an integer of 2 or more, or the word \'none\'\n$$usage\n";
	    }
	} else {
	    unless ($$options{'ranmax'} eq 'none') {
		die "\noption ranmax must be either an integer of 2 or more, or the word \'none\'\n$$usage\n";
	    }
	}
	## Cant be set if mmap is r or n
	if(($$options{'mmap'} eq 'n') or ($$options{'mmap'} eq 'r')) {
	    die "\noption ranmax cannot be set in conjunction with setting option mmap to 'n' or 'r'\n$$usage\n";
	}
    } elsif (exists($$options{'readfile'})) {
	# if it was unset by the user, set it to default of 3, unless mmap is set to none
	$$options{'ranmax'} = 3;
    }
}

sub validate_dicerminmax {
    my($options,$usage) = @_;  ## references to a hash and a scalar
    # set defaults, if needed
    unless(exists($$options{'dicermin'})) {
	$$options{'dicermin'} = 20;
    }
    unless(exists($$options{'dicermax'})) {
	$$options{'dicermax'} = 24;
    }
    # ensure that dicermin and max are integers, with value of 15 or higher
    unless($$options{'dicermin'} =~ /^\d+/) {
	die "\noption dicermin is invalid. It must be an integer of 15 or higher, and <= dicermax\n\n$$usage\n";
    }
    unless($$options{'dicermax'} =~ /^\d+/) {
	die "\noption dicermax is invalid. It must be an integer of 15 or higher, and >= dicermin\n\n$$usage\n";
    }
    unless(($$options{'dicermin'} >= 15) and ($$options{'dicermin'} <= $$options{'dicermax'})) {
	die "\noption dicermin is invalid. It must be an integer of 15 or higher, and <= dicermax\n\n$$usage\n";
    }
    unless(($$options{'dicermax'} >= 15) and ($$options{'dicermax'} >= $$options{'dicermin'})) {
	die "\noption dicermax is invalid. It must be an integer of 15 or higher, and >= dicermin\n\n$$usage\n";
    }
}

sub validate_pad {
    my ($options,$usage) = @_; ## references to a hash and a scalar
    # if not provided by user, set pad to default value of 75
    unless($$options{'pad'}) {
	$$options{'pad'} = 75;
    }
    # verify that pad is an integer
    unless($$options{'pad'} =~ /^\d+$/) {
	die "\noption pad is invalid. It must be an integer between 0 and 50000.\n\n$$usage\n";
    }
    # verify that pad is between 0 and 50000
    unless(($$options{'pad'} >= 0) and
	   ($$options{'pad'} <= 50000)) {
	die "\noption pad is invalid. It must be an integer between 0 and 50000.\n\n$$usage\n";
    }
}

sub validate_mincov {
    my ($options,$usage) = @_; ## references to a hash and a scalar
    my $float;
    # if not provided by user, set mincov to default value of 0.5 rpm (changed from 20  in 3.8 and upped from 5 as of v3.7).
    unless($$options{'mincov'}) {
	$$options{'mincov'} = '0.5rpm';
    }
    # verify that mincov is an integer or a float followed by 'rpm' or 'rpmm'
    unless(($$options{'mincov'} =~ /^\d+$/) or
	   ($$options{'mincov'} =~ /^[0-9]*\.[0-9]+|[0-9]+rpm$/) or
	   ($$options{'mincov'} =~ /^[0-9]*\.[0-9]+|[0-9]+rpmm$/)) {
	die "\noption mincov is invalid. It must be an integer between 1 and 50,000\n OR a floating point number >0 and < 500,000 followed  by \'rpm\' or \'rpmm\'.\n\n$$usage\n";
    }
    # If integer, verify that mincov is between 0 and 50000
    if ($$options{'mincov'} =~ /^\d+$/) {
	unless(($$options{'mincov'} >= 1) and
	       ($$options{'mincov'} <= 50000)) {
	    die "\noption mincov is invalid. It must be an integer between 1 and 50,000\n OR a floating point number >0 and < 500,000 followed  by \'rpm\' or \'rpmm\'.\n\n$$usage\n";
	}
    } else {
	# is a float followed by rpm or rpmm
	if($$options{'mincov'} =~ /^([0-9]*\.[0-9]+|[0-9]+)rpm{1,2}$/) {
	    $float = $1;
	    unless(($float > 0) and ($float < 500000)) {
	    die "\noption mincov is invalid. It must be an integer between 1 and 50,000\n OR a floating point number >0 and < 500,000 followed  by \'rpm\' or \'rpmm\'.\n\n$$usage\n";
	    }
	} else {
	    die "\noption mincov is invalid. It must be an integer between 1 and 50,000\n OR a floating point number >0 and < 500,000 followed  by \'rpm\' or \'rpmm\'.\n\n$$usage\n";
	}
    }
}

sub install_check {
    ## takes a program name and usage message, passed by value,
    ## and uses 'which' to find the install location
    ## returns the install location if found, or dies with usage message if not found
    my($program,$usage) = @_;
    open(WHICH, "which $program |");
    my $path = <WHICH>;
    close WHICH;
    chomp $path;
    if($path) {
	return $path;
    } else {
	die "\nRequired dependency $program not found in PATH.\n\n$usage\n";
    }
}

sub samtools_version1_check {
    ## takes usage statement as input, passed by value
    ## calls 'samtools --version' to get the version number
    ## dies and complains unless there is a response that matches 1. in the version number.
    my($usage) = @_;
    open(V, "samtools --version |");
    my $vline = <V>;
    close V;
    chomp $vline;
    $vline =~ s/samtools//g;
    $vline =~ s/\s//g;
    if($vline) {
	if($vline =~ /^1\./) {
	    return $vline;
	} else {
	    die "\nInvalid version of samtools installed \($vline\). Needs to be version 1.x\n\n$usage\n";
	}
    } else {
	die "\nInvalid version of samtools installed. Needs to be version 1.x\n\n$usage\n";
    }
}

sub fai {
    ## checks whether the genome file stored in $$options{'genomefile'} has a .fai index
    ## if not, tries to create it
    ## Input is options hash, passed by reference
    ## Output is the .fai file path
    my($options) = @_;
    my $expected_fai = "$$options{'genomefile'}" . ".fai";
    if(-r $expected_fai) {
	return $expected_fai;
    } else {
	my $time = `date`;
	chomp $time;
	log_it($$options{'logfile'}, "\n$time");
	log_it($$options{'logfile'}, "Expected fai file $expected_fai not found. Attempting to create using samtools faidx ...");
	system "samtools faidx $$options{'genomefile'}";
	if(-r $expected_fai) {
	    log_it($$options{'logfile'}, "\tSuccessful");
	    return $expected_fai;
	} else {
	    log_it($$options{'logfile'}, "\tFailed. Aborting Run");
	    exit;
	}
    }
}

sub fai_stitch {
    ## checks whether the genome file stored in $$options{'stitchgenomefile'} has a .fai index
    ## if not, tries to create it .. silently
    ## Input is options hash, passed by reference
    ## Output is the .fai file path
    my($options) = @_;
    my $expected_fai = "$$options{'stitchgenomefile'}" . ".fai";
    if(-r $expected_fai) {
	return $expected_fai;
    } else {
	system "samtools faidx $$options{'stitchgenomefile'}";
	if(-r $expected_fai) {
	    return $expected_fai;
	} else {
	    log_it($$options{'logfile'}, "\tFailed to make fai of stitched genome. Aborting Run");
	    exit;
	}
    }
}

sub need_to_stitch {
    # Input is a reference to the options hash
    # Checks the genome's fai file, and determines whether stitching is warranted
    # Stitching for chunks less than 1Mb if there are > 50 chunks in the assembly

    my($options) = @_;

    my $fai = "$$options{'genomefile'}" . ".fai";

    # ensure fai is readable
    unless(-r $fai) {
	log_it($$options{'logfile'}, "\nFATAL in sub-routine need_to_stitch: fai file $fai was not readable");
	exit;
    }

    my $n = 0; ## count of references

    my $small = 0; ## tally of references that are < 1Mb in length

    open(FAI, "$fai");
    while (<FAI>) {
	my @fai_fields = split ("\t", $_);
	++$n;
	if($fai_fields[1] < 1E6) {
	    ++$small;
	}
    }
    close FAI;

    if($n <= 50) {
	return 0; ## never stitch if there are 50 or fewer chromosomes
    } elsif ($small >= 2) {
	# if there are 2 or more chromosomes of < 1Mb in size, stitch is turned on
	# as of 3.8, stich size is always 100
	my $st_size = 100;
	return $st_size;
    } else {
	return 0; ## was more than 50 chromosomes, but no more than 1 were < 1Mb in length, so no stitching
    }
}


sub stitch_genome {
    ## Input is a reference to the options hash.
    my($options,$gap_size) = @_;  ## references to hash, scalar

    # report
    my $time = `date`;
    chomp $time;
    log_it($$options{'logfile'}, "\n$time");
    log_it($$options{'logfile'}, "Genome has more than 50 segments and more than two of them are < 1Mb. Stitching short references to improve performance ...");

    # As of 3.8, these warnings are no longer needed. Results, bamfile, etc. will still be relative to original genome.
    ##log_it($$options{'logfile'}, "\tNOTE: This will make a modified version of your genome. To avoid genome stitching, abort");
    ##log_it($$options{'logfile'}, "\tthis run, and start a new one with option --nostitch");

    # Create a file for the new, stitched genome
    my($og,$og_path,$og_suffix) = fileparse($$options{'genomefile'}, qr/\.[^\.]+$/);
    my $sg_file = "$$options{'outdir'}" . "/$og" . "_stitched" . "$og_suffix";
    open(SG, ">>$sg_file");

    # Create a file that summarizes the changes in the stitched genome
    # This file is no longer needed. Data stored in hash during run, then stitched genome will be deleted.
    #my $sg_guide_file = "$$options{'outdir'}" . "/$og" . "_stitched" . "_guide.txt";
    #open(SGG, ">$sg_guide_file");

    # Initialize counter for 'stitches' and other variables
    my $x = 0;
    my $stitch_seq;
    my $current_seq;
    my $orig_head;
    my $start;
    my $stop;

    # get the strings of N's to be added all over the place
    my $Ns;
    for(my $k = 1; $k <= $$gap_size; ++$k) {
	$Ns .= "N";
    }

    # TEST
    #my $y = 0;
    # END TEST

    # Open the original genome FA file, and go through it
    open(FA, "$$options{'genomefile'}");
    while (<FA>) {
	if($_ =~ /^>(\S+)/) {
	    if($current_seq) {
		# remove new lines, etc, from current chr
		$current_seq =~ s/\s//g;
		$current_seq =~ s/\n//g;
		if($stitch_seq) {
		    # stop stitching if current_seq by itself is >= 5E7 nts
		    if((length $current_seq) >= 5E7) {
			print SG ">stitch", "_$x\n";
			# format and print
			$stitch_seq =~ s/(.{60})/$1\n/g;
			if($stitch_seq =~ /\n$/) {
			    print SG "$stitch_seq";
			} else {
			    print SG "$stitch_seq\n";
			}
			$stitch_seq = '';
			++$x;

			# Now output current_seq untouched
			$start = 1;
			$stop = length $current_seq;
			#print SGG "$orig_head\t$orig_head\t$start\t$stop\n";
			$$options{'stitchguide'}{$orig_head} = $orig_head . ':' . $start . '-' . $stop;
			$current_seq =~ s/(.{60})/$1\n/g;
			print SG ">$orig_head\n";
			if($current_seq =~ /\n$/) {
			    print SG "$current_seq";
			} else {
			    print SG "$current_seq\n";
			}
		    } else {
			## Add to the current stitch seq, update SGG, and
			## then check to see if it exceeds 5E7
			$stitch_seq .= "$Ns";
			$start = (length $stitch_seq) + 1;
			$stitch_seq .= $current_seq;
			$stop = length $stitch_seq;
			#print SGG "$orig_head\tstitch_$x\t$start\t$stop\n";
			$$options{'stitchguide'}{$orig_head} = 'stitch_' . $x . ':' . $start . '-' . $stop;
			if((length $stitch_seq) >= 5E7) {
			    print SG ">stitch", "_$x\n";
			    # format and print
			    $stitch_seq =~ s/(.{60})/$1\n/g;
			    if($stitch_seq =~ /\n$/) {
				print SG "$stitch_seq";
			    } else {
				print SG "$stitch_seq\n";
			    }

			    $stitch_seq = '';
			    ++$x;
			}
		    }
		} else {
		    # check length of current seq ...
		    if((length $current_seq) < 5E7) {
			# stitch time!
			$stitch_seq = $current_seq;
			$start = 1;
			$stop = length($stitch_seq);
			#print SGG "$orig_head\tstitch_$x\t$start\t$stop\n";
			$$options{'stitchguide'}{$orig_head} = 'stitch_' . $x . ':' . $start . '-' . $stop;
		    } else {
			# output as is .. after formatting
			$start = 1;
			$stop = length $current_seq;
			#print SGG "$orig_head\t$orig_head\t$start\t$stop\n";
			$$options{'stitchguide'}{$orig_head} = $orig_head . ':' . $start . '-' . $stop;
			$current_seq =~ s/(.{60})/$1\n/g;
			print SG ">$orig_head\n";
			if($current_seq =~ /\n$/) {
			    print SG "$current_seq";
			} else {
			    print SG "$current_seq\n";
			}
		    }
		}
	    }
	    # reset current_seq
	    $current_seq = '';
	    # store the original header
	    $orig_head = $1;
	} else {
	    # a sequence line
	    $current_seq .= $_;
	}
    }
    close FA;

    # last one...
    # remove new lines, etc, from current chr
    $current_seq =~ s/\s//g;
    $current_seq =~ s/\n//g;
    if($stitch_seq) {
	# stop stitching if current_seq by itself is >= 5E7 nts
	if((length $current_seq) >= 5E7) {
	    print SG ">stitch", "_$x\n";
	    # format and print
	    $stitch_seq =~ s/(.{60})/$1\n/g;
	    if($stitch_seq =~ /\n$/) {
		print SG "$stitch_seq";
	    } else {
		print SG "$stitch_seq\n";
	    }
	    $stitch_seq = '';
	    ++$x;

	    # Now output current_seq untouched
	    $start = 1;
	    $stop = length $current_seq;
	    #print SGG "$orig_head\t$orig_head\t$start\t$stop\n";
	    $$options{'stitchguide'}{$orig_head} = $orig_head . ':' . $start . '-' . $stop;
	    $current_seq =~ s/(.{60})/$1\n/g;
	    print SG ">$orig_head\n";
	    if($current_seq =~ /\n$/) {
		print SG "$current_seq";
	    } else {
		print SG "$current_seq\n";
	    }
	} else {
	    ## Add to the current stitch seq, update SGG, and
	    #### Output the stitch seq cause it's the last one
	    $stitch_seq .= "$Ns";
	    $start = (length $stitch_seq) + 1;
	    $stitch_seq .= $current_seq;
	    $stop = length $stitch_seq;
	    #print SGG "$orig_head\tstitch_$x\t$start\t$stop\n";
	    $$options{'stitchguide'}{$orig_head} = 'stitch_' . $x . ':' . $start . '-' . $stop;
	    print SG ">stitch", "_$x\n";
	    # format and print
	    $stitch_seq =~ s/(.{60})/$1\n/g;
	    if($stitch_seq =~ /\n$/) {
		print SG "$stitch_seq";
	    } else {
		print SG "$stitch_seq\n";
	    }

	    $stitch_seq = '';
	    ++$x;
	}
    } else {
	# output it, cuz its the last one
	# output as is .. after formatting
	$start = 1;
	$stop = length $current_seq;
	#print SGG "$orig_head\t$orig_head\t$start\t$stop\n";
	$$options{'stitchguide'}{$orig_head} = $orig_head . ':' . $start . '-' . $stop;
	$current_seq =~ s/(.{60})/$1\n/g;
	print SG ">$orig_head\n";
	if($current_seq =~ /\n$/) {
	    print SG "$current_seq";
	} else {
	    print SG "$current_seq\n";
	}
    }

    close SG;
    #close SGG;

    # Report
    ##$$options{'genomefile'} = $sg_file;
    $$options{'stitchgenomefile'} = $sg_file;

    # fai it
    my $fai_file = fai_stitch($options);

    # note that $$options{'stitchguide'} also has entries after this.

    log_it($$options{'logfile'}, "\tDone");
    return $fai_file;
}

sub ebwt {
    # Input is a reference to the options hash
    # This sub-routine checks if the .ebwt(l) indices for the genomefile exist,
    # and if not, tries to create them with bowtie-build
    my($options) = @_;

    # do we need regular indices, colorspace indices, or both? check readfiles.
    my($basespace,$colorspace) = readfile_space_check($options);
    unless(($basespace) or ($colorspace)) {
	log_it($$options{'logfile'}, "\nFATAL in sub-routine ebwt .. file types of readfiles unknown");
	exit;
    }

    # get file basename for genome
    my @suffices = ('.fa', '.fasta');
    my($gen_file,$gen_path,$gen_suffix) = fileparse($$options{'genomefile'}, @suffices);

    # variable to store type .. large or small
    my $itype;


    # check and build base-space indices
    if($basespace) {
	my $one = $gen_path . $gen_file . ".1.ebwt";
	my $two = $gen_path . $gen_file . ".2.ebwt";
	my $three = $gen_path . $gen_file . ".3.ebwt";
	my $four = $gen_path . $gen_file . ".4.ebwt";
	my $rev1 = $gen_path . $gen_file . ".rev.1.ebwt";
	my $rev2 = $gen_path . $gen_file . ".rev.2.ebwt";

	my $onel = "$one" . "l";
	my $twol = "$two" . "l";
	my $threel = "$three" . "l";
	my $fourl = "$four" . "l";
	my $rev1l = "$rev1" . "l";
	my $rev2l = "$rev2" . "l";

	if((-r $one) and (-r $two) and (-r $three) and (-r $four) and (-r $rev1) and (-r $rev2)) {
	    $itype = 's';
	    return $itype;
	} elsif ((-r $onel) and (-r $twol) and (-r $threel) and (-r $fourl) and (-r $rev1l) and (-r $rev2l)) {
	    $itype = 'l';
	    return $itype;
	} else {
	    my $time = `date`;
	    chomp $time;
	    log_it($$options{'logfile'}, "\n$time");
	    log_it ($$options{'logfile'}, "Expected bowtie indices not found. Attempting to make them with bowtie-build...");
	    my $base = $gen_path . $gen_file;

	    # determine if large-index needs to be called or not
	    my $large = is_large($options);
	    if($large) {
		system "bowtie-build --large-index $$options{'genomefile'} $base >> $$options{'error_logfile'}";
		unless(((-r $one) and (-r $two) and (-r $three) and (-r $four) and (-r $rev1) and (-r $rev2)) or
		       ((-r $onel) and (-r $twol) and (-r $threel) and (-r $fourl) and (-r $rev1l) and (-r $rev2l))) {
		    log_it ($$options{'logfile'}, "\tFAILED. Aborting.");
		    exit;
		}
	    } else {
		system "bowtie-build $$options{'genomefile'} $base >> $$options{'error_logfile'}";
		unless(((-r $one) and (-r $two) and (-r $three) and (-r $four) and (-r $rev1) and (-r $rev2)) or
		       ((-r $onel) and (-r $twol) and (-r $threel) and (-r $fourl) and (-r $rev1l) and (-r $rev2l))) {
		    log_it ($$options{'logfile'}, "\tFAILED. Aborting.");
		    exit;
		}
	    }
	    log_it ($$options{'logfile'}, "\tSuccessful");
	    if(-r $one) {
		$itype = 's';
	    } elsif (-r $onel) {
		$itype = 'l';
	    }
	    return $itype;
	}
    }

    # check and build color-space indices
    if($colorspace) {
	my $one = $gen_path . $gen_file . ".cs.1.ebwt";
	my $two = $gen_path . $gen_file . ".cs.2.ebwt";
	my $three = $gen_path . $gen_file . ".cs.3.ebwt";
	my $four = $gen_path . $gen_file . ".cs.4.ebwt";
	my $rev1 = $gen_path . $gen_file . ".cs.rev.1.ebwt";
	my $rev2 = $gen_path . $gen_file . ".cs.rev.2.ebwt";

	my $onel = "$one" . "l";
	my $twol = "$two" . "l";
	my $threel = "$three" . "l";
	my $fourl = "$four" . "l";
	my $rev1l = "$rev1" . "l";
	my $rev2l = "$rev2" . "l";

	if ((-r $one) and (-r $two) and (-r $three) and (-r $four) and (-r $rev1) and (-r $rev2)) {
	    $itype = 's';
	    return $itype;
	} elsif ((-r $onel) and (-r $twol) and (-r $threel) and (-r $fourl) and (-r $rev1l) and (-r $rev2l)) {
	    $itype = 'l';
	    return $itype;
	} else {
	    my $time = `date`;
	    chomp $time;
	    log_it($$options{'logfile'}, "\n$time");
	    log_it ($$options{'logfile'}, "Expected color-space bowtie indices not found. Attempting to make them with bowtie-build...");
	    my $base = $gen_path . $gen_file . ".cs";

	    # determine if large-index needs to be called or not
	    my $large = is_large($options);
	    if($large) {
		system "bowtie-build -C --large-index $$options{'genomefile'} $base >> $$options{'error_logfile'}";
		unless(((-r $one) and (-r $two) and (-r $three) and (-r $four) and (-r $rev1) and (-r $rev2)) or
		       ((-r $onel) and (-r $twol) and (-r $threel) and (-r $fourl) and (-r $rev1l) and (-r $rev2l))) {
		    log_it ($$options{'logfile'}, "\tFAILED. Aborting.");
		    exit;
		}
	    } else {
		system "bowtie-build -C $$options{'genomefile'} $base >> $$options{'error_logfile'}";
		unless(((-r $one) and (-r $two) and (-r $three) and (-r $four) and (-r $rev1) and (-r $rev2)) or
		       ((-r $onel) and (-r $twol) and (-r $threel) and (-r $fourl) and (-r $rev1l) and (-r $rev2l))) {
		    log_it ($$options{'logfile'}, "\tFAILED. Aborting.");
		    exit;
		}
	    }

	    log_it ($$options{'logfile'}, "\tSuccessful");
	    if(-r $one) {
		$itype = 's';
	    } elsif (-r $onel) {
		$itype = 'l';
	    }
	    return $itype;
	}
    }
}

sub readfile_space_check {
    # Input is a reference to the options hash
    # Checks whether readfiles are in base space, color-space, or if there is a mixture of both
    my($options) = @_;
    my $basespace;
    my $colorspace;
    foreach my $file_entry (@{$$options{'readfile'}}) {
	my ($file,$path,$suffix) = fileparse($file_entry, qr/\.\S+$/);
	if($suffix =~ /csfasta/) {
	    ++$colorspace;
	} elsif (($suffix =~ /\.fa/) or ($suffix =~ /\.fq/)) {
	    ++$basespace;
	}
    }
    return ($basespace,$colorspace);
}

sub trim_master {
    # Input: references to options hash, adapters array
    # Output: Array containing the filepaths to the trimmed files
    my($options,$adapters) = @_;
    my @trimmed_files = ();
    my $trimmed;
    my $cqualfile;
    my $i = 0;
    foreach my $readfile (@{$$options{'readfile'}}) {
	my($readfilebase,$readfilepath,$readfilesuffix) = fileparse($readfile, qr/\.\S+$/);

	# use reg-ex's for these checks, since the whole suffix could end in .gz or not

	if(($readfilesuffix =~ /\.csfasta$/) or ($readfilesuffix =~ /\.csfasta\.gz$/)) {
	    if(exists($$options{'cquals'})) {
		$cqualfile = ${$$options{'cquals'}}[$i];
		++$i;
		$trimmed = trim_csfasta_and_qual(\$readfile,$adapters,$options,\$cqualfile);
		push(@trimmed_files, $trimmed);
		## Note that the trimmed qual file will have same path and basename as trimmed reads, just a .qual(.gz) extension instead of .csfasta(.gz).
	    } else {
		$trimmed = trim_csfasta(\$readfile,$adapters,$options);
		push(@trimmed_files, $trimmed);
	    }
	} elsif (($readfilesuffix =~ /\.fastq$/) or ($readfilesuffix =~ /\.fastq\.gz$/) or
		 ($readfilesuffix =~ /\.fq$/) or ($readfilesuffix =~ /\.fq\.gz$/))  {
	    $trimmed = trim_fastq(\$readfile,$adapters,$options);
	    push(@trimmed_files, $trimmed);
	} elsif (($readfilesuffix =~ /\.fa$/) or ($readfilesuffix =~ /\.fa\.gz$/) or
		 ($readfilesuffix =~ /\.fasta$/) or ($readfilesuffix =~ /\.fasta\.gz$/)){
	    $trimmed = trim_fasta(\$readfile,$adapters,$options);
	    push(@trimmed_files, $trimmed);
	}
    }
    return @trimmed_files;
}

sub trim_fasta {
    # Input: references to readfile (scalar), adapters (array), and options (hash)
    # Output: filepath to trimmed reads
    my($reads,$adapters,$options) = @_;

    #Determine if the reads are gzip compressed
    my $gz;
    if($$reads =~ /\.gz$/) {
	$gz = 1;
    }
    my @suffices = ('.fa', '.fasta', '.fa.gz', '.fasta.gz', '.fq', '.fastq', '.fastq.gz', '.fq.gz', '.csfasta', '.csfasta.gz');
    # Open the output file
    my ($readbase,$readpath,$readsuffix) = fileparse($$reads, @suffices);

    my $outfile = $$options{'outdir'} . "/" . $readbase . "_trimmed" . $readsuffix;
    if($gz) {
	open(OUT, "| gzip >> $outfile");
    } else {
	open(OUT, ">>$outfile");
    }

    # Open the input stream to trim
    if($gz) {
	open(IN, "gzip -d -c $$reads |");
    } else {
	open(IN, "$$reads");
    }

    # Get the adapter (in base space)
    my $adapter = shift @$adapters;
    unless($$adapters[0]) {
	unshift (@$adapters, $adapter);
    }

    # Talk to user
    my $time = `date`;
    chomp $time;
    log_it($$options{'logfile'}, "\n$time");
    log_it($$options{'logfile'}, "Adapter trimming input reads file $$reads with adapter $adapter");

    # Some variables
    my $head;
    my $trim_len;
    my $trim_seq;
    my $in = 0;
    my $ok = 0;

    # Read through
    while (<IN>) {
	my $long_head = $_;
	chomp $long_head;
	my $long_seq = <IN>;
	chomp $long_seq;

	# Crude validation of FASTA format
	unless($long_head =~ /^>/) {
	    log_it($$options{'logfile'}, "\tFATAL in sub-routine trim_fasta: Invalid FASTA format encountered at:");
	    log_it($$options{'logfile'}, "\t$long_head\n\t$long_seq");
	    exit;
	}
	++$in;

	# look for it...
	$trim_len = 0;
	while ($long_seq =~ /$adapter/ig) {
	    $trim_len = (pos $long_seq) - (length $adapter);
	}
	if($trim_len >= 15) {
	    $trim_seq = substr($long_seq, 0, $trim_len);
	    if($trim_seq =~ /^[ATGC]+$/) {
		++$ok;
		$head = $long_head;
		$head =~ s/\s.*$//g;
		$head .= "t"; ## t is for trimmed
		print OUT "$head\n$trim_seq\n";
	    }
	}
    }
    close IN;
    close OUT;
    log_it($$options{'logfile'}, "\tComplete: $ok out of $in reads successfully trimmed");
    return $outfile;
}

sub trim_fastq {
    # Input: references to readfile (scalar), adapters (array), and options (hash)
    # Output: filepath to trimmed reads
    my($reads,$adapters,$options) = @_;

    #Determine if the reads are gzip compressed
    my $gz;
    if($$reads =~ /\.gz$/) {
	$gz = 1;
    }
    my @suffices = ('.fa', '.fasta', '.fa.gz', '.fasta.gz', '.fq', '.fastq', '.fastq.gz', '.fq.gz', '.csfasta', '.csfasta.gz');
    # Open the output file
    my ($readbase,$readpath,$readsuffix) = fileparse($$reads, @suffices);
    my $outfile = $$options{'outdir'} . "/" . $readbase . "_trimmed" . $readsuffix;
    if($gz) {
	open(OUT, "| gzip >> $outfile");
    } else {
	open(OUT, ">>$outfile");
    }

    # Open the input stream to trim
    if($gz) {
	open(IN, "gzip -d -c $$reads |");
    } else {
	open(IN, "$$reads");
    }

    # Get the adapter (in base space)
    my $adapter = shift @$adapters;
    unless($$adapters[0]) {
	unshift (@$adapters, $adapter);
    }

    # Talk to user
    my $time = `date`;
    chomp $time;
    log_it($$options{'logfile'}, "\n$time");
    log_it($$options{'logfile'}, "Adapter trimming input reads file $$reads with adapter $adapter");

    # Some variables
    my $head;
    my $trim_len;
    my $trim_seq;
    my $trim_qual;
    my $in = 0;
    my $ok = 0;

    # Read through
    while (<IN>) {
	my $long_head = $_;
	chomp $long_head;
	my $long_seq = <IN>;
	chomp $long_seq;
	my $plus = <IN>;
	my $long_qual = <IN>;
	chomp $long_qual;

	# Crude validation of FASTQ format
	unless(($long_head =~ /^\@/) and
	       ((length $long_seq) == (length $long_qual)) and
	       ($plus =~ /^\+/)) {
	    log_it($$options{'logfile'}, "\tFATAL in sub-routine trim_fastq: Invalid FASTQ format in input reads file $$reads at");
	    log_it($$options{'logfile'}, "\t$long_head\n\t$long_seq\n\t$plus\t$long_qual");
	    exit;
	}
	++$in;

        # Look for match
	$trim_len = 0;
	while ($long_seq =~ /$adapter/ig) {
	    $trim_len = (pos $long_seq) - (length $adapter);
	}

	if($trim_len >= 15) {
	    $trim_seq = substr($long_seq, 0, $trim_len);
	    if($trim_seq =~ /^[ATGC]+$/) {
		$trim_qual = substr($long_qual, 0, $trim_len);
		$head = $long_head;
		$head =~ s/\s.*$//g;
		$head .= "t"; # t is for trimmed
		print OUT "$head\n", "$trim_seq\n", "+\n", "$trim_qual\n";
		++$ok;
	    }
	}
    }
    close IN;
    close OUT;
    log_it($$options{'logfile'}, "\tComplete: $ok out of $in reads successfully trimmed");
    return $outfile;
}

sub trim_csfasta {
    # Input: references to readfile (scalar), adapters (array), and options (hash)
    # Output: filepath to trimmed reads
    my($reads,$adapters,$options) = @_;

    #Determine if the reads are gzip compressed
    my $gz;
    if($$reads =~ /\.gz$/) {
	$gz = 1;
    }
    my @suffices = ('.fa', '.fasta', '.fa.gz', '.fasta.gz', '.fastq.gz', '.fq.gz', '.csfasta', '.csfasta.gz');
    # Open the output file
    my ($readbase,$readpath,$readsuffix) = fileparse($$reads, @suffices);

    my $outfile = $$options{'outdir'} . "/" . $readbase . "_trimmed" . $readsuffix;
    if($gz) {
	open(OUT, "| gzip >> $outfile");
    } else {
	open(OUT, ">>$outfile");
    }

    # Open the input stream to trim
    if($gz) {
	open(IN, "gzip -d -c $$reads |");
    } else {
	open(IN, "$$reads");
    }

    # Get the adapter (in base space)
    my $adapter = shift @$adapters;
    unless($$adapters[0]) {
	unshift (@$adapters, $adapter);
    }

    # Talk to user
    my $time = `date`;
    chomp $time;
    log_it($$options{'logfile'}, "\n$time");
    log_it($$options{'logfile'}, "Adapter trimming input reads file $$reads with adapter $adapter");

    # Translate the adapter to colorspace
    my $adapter_cs = base2color($adapter);

    # Some variables
    my $head;
    my $trim_len;
    my $trim_seq;
    my $in = 0;
    my $ok = 0;


    # Read through
    while (<IN>) {
	if($_ =~ /^\#/) {
	    next; ## remember that csfasta files can have comments
	}
	chomp;
	if($_ =~ /^(>\S+)/) {
	    $head = "$1" . "t\n";
	    ++$in;
	} else {
	    $trim_len = 0;
	    while($_ =~ /$adapter_cs/ig) {
		$trim_len = (pos $_) - (length $adapter_cs) - 1; # subtract 1 to remove the hybrid color .. leading T is still included, so sRNA length is trim_len - 1
	    }
	    if($trim_len >= 16) {  ## Meaning actual read is 15 or more .. the leading T is still included in $trim_len
		$trim_seq = substr($_,0,$trim_len);  ## hybrid color is removed
		if($trim_seq =~ /^[ATGC][0123]+$/) {
		    ++$ok;
		    print OUT $head, $trim_seq, "\n";
		}
	    }
	}
    }
    close IN;
    close OUT;

    # Talk to user
    log_it($$options{'logfile'}, "\tComplete: $ok out of $in reads successfully trimmed");
    return $outfile;
}

sub trim_csfasta_and_qual {
    # Input: references to readfile (scalar), adapters (array), and options (hash), and cqual file (scalar)
    # Output: filepath to trimmed reads
    my($reads,$adapters,$options,$quals) = @_;

    #Determine if the reads are gzip compressed
    my $gz;
    if($$reads =~ /\.gz$/) {
	$gz = 1;
    }

    # Open the output files for reads and quals
    my ($readbase,$readpath,$readsuffix) = fileparse($$reads, qr/\.[^\.]+$/); ## suffix only after LAST .
    my $outfile = $$options{'outdir'} . "/" . $readbase . "_trimmed" . $readsuffix;
    my $q_outfile = $$options{'outdir'} . "/" . $readbase . "_trimmed" . ".qual";
    if($gz) {
	open(OUT, "| gzip >> $outfile");
    } else {
	open(OUT, ">>$outfile");
    }

    # trimmed quality values are not ever gzip-compressed
    open(QOUT, ">>$q_outfile");

    # Open the input stream to trim
    if($gz) {
	open(IN, "gzip -d -c $$reads |");
    } else {
	open(IN, "$$reads");
    }
    open (QIN, "$$quals");

    # Get the adapter (in base space)
    my $adapter = shift @$adapters;
    unless($$adapters[0]) {
	unshift (@$adapters, $adapter);
    }

    # Talk to user
    my $time = `date`;
    chomp $time;
    log_it($$options{'logfile'}, "\n$time");
    log_it($$options{'logfile'}, "Adapter trimming input reads file $$reads and qual file $$quals with adapter $adapter");

    # Translate the adapter to colorspace
    my $adapter_cs = base2color($adapter);

    # Some variables
    my $head;
    my $trim_len;
    my $trim_seq;
    my $in = 0;
    my $ok = 0;
    my $trim_qual;
    my $qin_line;

    # Read through
    while (<IN>) {
	$qin_line = <QIN>;
	if($_ =~ /^\#/) {
	    next; ## remember that csfasta files can have comments
	}
	chomp;
	if($_ =~ /^(>\S+)/) {
	    $head = "$1" . "t\n";  ## The t is for 'trimmed'
	    ++$in;
	} else {
	    $trim_len = 0;
	    while($_ =~ /$adapter_cs/ig) {
		$trim_len = (pos $_) - (length $adapter_cs) - 1; # subtract 1 to remove the hybrid color .. leading T is still included, so sRNA length is trim_len - 1
	    }
	    if($trim_len >= 16) {  ## Meaning actual read is 15 or more .. the leading T is still included in $trim_len
		$trim_seq = substr($_,0,$trim_len);  ## hybrid color is removed
		if($trim_seq =~ /^[ATGC][0123]+$/) {
		    ++$ok;
		    print OUT $head, $trim_seq, "\n";
		    # parse the quality string
		    print QOUT $head;
		    my @qual_fields = split (" ", $qin_line);
		    my @qf_out = ();
		    for(my $j = 0; $j < ($trim_len - 1); ++$j) {
			push(@qf_out, $qual_fields[$j]);
		    }
		    $trim_qual = join(" ", @qf_out);
		    print QOUT $trim_qual, "\n";
		}
	    }
	}
    }
    close IN;
    close OUT;
    close QIN;
    close QOUT;

    # Talk to user
    log_it($$options{'logfile'}, "\tComplete: $ok out of $in reads successfully trimmed");
    return $outfile;
}

sub base2color {
    # Input: passed by value .. an upper-case ATGC string that has already been validated
    # Output: Colorspace translation of the same
    my($dna) = @_;

    my %colors = (
        'AA' => 0,
        'CC' => 0,
        'GG' => 0,
        'TT' => 0,
        'AC' => 1,
        'CA' => 1,
        'GT' => 1,
        'TG' => 1,
        'AG' => 2,
        'CT' => 2,
        'GA' => 2,
        'TC' => 2,
        'AT' => 3,
        'CG' => 3,
        'GC' => 3,
        'TA' => 3,
        );
    my $dibase;
    my $color_adapter;
    my @letters = split('', $dna);
    for(my $i = 0; $i <= ((scalar @letters) - 2); ++$i) {
        $dibase = "$letters[$i]" . "$letters[($i + 1)]";
        $color_adapter .= $colors{$dibase};
    }
    return $color_adapter;
}

sub validate_cquals {
    # Input is two references .. to options hash, usage message scalar

    my($options,$usage) = @_;

    # If user provides cquals, readfile must also be used
    unless(exists($$options{'readfile'})) {
	die "\nIf option --cquals is used, option --readfile must also be used\n$$usage\n";
    }

    # If user provided cquals, ALL of the read files must be .csfasta or .csfasta.gz
    foreach my $readfile (@{$$options{'readfile'}}) {
	my($rname,$rpath,$rsuffix) = fileparse($readfile, qr/\.\S+$/);
	unless(($rsuffix eq ".csfasta") or
	       ($rsuffix eq ".csfasta.gz")) {
	    die "\nIf option --cquals is used, all read files given in option --readfile must be .csfasta or .csfasta.gz\n$$usage\n";
	}
    }

    # Check if each qual file is readable and has suffix .qual (NO .gz allowed!)
    foreach my $qf (@{$$options{'cquals'}}) {
	my($qname,$qpath,$qsuffix) = fileparse($qf, qr/\.[^\.]+$/);
	(open(FILE, "$qf")) || die "\nColor-space quality file $qf from option --cquals was not readable\n$$usage\n";
	close FILE;
	unless($qsuffix eq ".qual") {
	    die "\nColor-space quality file $qf did not end with required suffix, .qual\n\n$$usage\n";
	}
    }

    # readfiles and cquals must be the same number when cquals is set
    unless((scalar @{$$options{'readfile'}}) == (scalar @{$$options{'cquals'}})) {
	die "\nWhen option --cquals is used, the number of readfiles from --readfile must be the same as the number of quality files from --cquals\n$$usage\n";
    }
}

sub align_master {
    # Master controlling sub-routine for alignments
    # Input: references to options hash, trimmed readfiles, version number and command line
    # End result .. $$options{'bamfile'} or $$options{'cramfile'} is set, and the file itself is also indexed
    my($options,$t_readfiles,$version_num,$command_line) = @_;

    my @read_sorted = ();  # These are the initial read-sorted BAM files before the selection of primary alignments and merging

    my $i = 0;
    my $cqualfile;

    # Initialize density hash
    # This will be un-used when --mmap is set to n or r
    my %density = ();

    foreach my $t_readfile (@$t_readfiles) {
	my($base,$path,$suffix) = fileparse($t_readfile, qr/\.[^\.]+$/);

        # Check about cqualfiles ...
        #   if the array is not empty, then, if options{'adapter'} exists, ShortStack trimmed them .. if not, they were already trimmed by user
	if(exists($$options{'cquals'})) {
	    if($$options{'adapter'}) {
		# parse the filepath of the readfile ... the ShortStack-trimmed cqual file will the same, just with suffix .qual
		$cqualfile = $path . $base . '.qual';
	    } else {
		$cqualfile = ${$$options{'cquals'}}[$i];
	    }
	    # Verify qualfile
	    unless(open(FILE, "$cqualfile")) {
		log_it($$options{'logfile'}, "\nFATAL in sub-routine align_master: Failed to find expected color-space quality file $cqualfile\n");
		exit;
	    }
	    close FILE;
	    ++$i;
	    # double-check that the trimmmed reads are .csfasta format (or .csfasta.gz).
	    unless(($suffix eq '.csfasta') or (($suffix eq '.gz') and ($base =~ /\.csfasta$/))) {
		log_it($$options{'logfile'}, "\nFATAL in sub-routine align_master : color-space quality values found but read file $t_readfile does not appear to be a csfasta or csfasta.gz file\n");
		exit;
	    }
	}
	# call alignment sub-routine, getting back the file path
	my $read_s_aln = get_read_s_aln($options,\$t_readfile,\$cqualfile,\%density);
	push(@read_sorted, $read_s_aln);
    }

    # Compute probabilities, and assign primary / secondary alignment designations
    my @sorted_bams = decider($options,\@read_sorted,\%density,$version_num,$command_line);

    # Merge bamfiles, if needed
    my $final_bam;
    if((scalar @sorted_bams) > 1) {
	$final_bam = merge_bams(\@sorted_bams, $options);
    } else {
	$final_bam = $sorted_bams[0];
    }

    # Convert to cram, if needed
    if($$options{'cram'}) {
	$$options{'cramfile'} = bam2cram(\$final_bam, $options);
	log_it($$options{'logfile'}, "Alignment completed. Final cram file is $$options{'cramfile'}");
    } else {
	$$options{'bamfile'} = $final_bam;
	log_it($$options{'logfile'}, "Alignment completed. Final bam file is $$options{'bamfile'}");
    }
}

sub get_read_s_aln {
    # Controls bowtie to align reads, note number of alignments for each read, and track
    #  genome-wide densities in 50 nt bins (unless mmap is r or n)
    # Input: references to options hash, trimmed readfile, trimmed cqual file, and density hash
    # Output: file path of the read-sorted sam.gz file

    my($options,$reads,$cqual,$density) = @_;


    # Determine formatting of reads input
    my $stripped_reads = $$reads;
    my $gz;
    if($stripped_reads =~ /\.gz$/) {
	$gz = 1;
	$stripped_reads =~ s/\.gz$//;
    }

    my($base,$path,$suffix) = fileparse($stripped_reads, qr/\.[^\.]+$/);
    my $format;
    if($suffix eq '.csfasta') {
	$format = "-C -f";
    } elsif (($suffix eq '.fasta') or ($suffix eq '.fa')) {
	$format = "-f";
    } elsif (($suffix eq '.fastq') or ($suffix eq '.fq')) {
	$format = "-q";
    } else {
	log_it($$options{'logfile'}, "\nFATAL in sub-routine get_read_s_aln : Could not determine format of reads file $$reads");
	exit;
    }

    # Determine the ebwt base name
    my($gbase,$gpath,$gsuffix) = fileparse($$options{'genomefile'}, qr/\.[^\.]+$/);
    my $ebwt_base = $gpath . $gbase;
    ## $ebwt_base =~ s/$gsuffix//g;
    if($format =~ /C/) {
	$ebwt_base .= ".cs";
    }

    # Determine output file name
    my $outfile = $$options{'outdir'} . "\/" . $base . "_readsorted.sam.gz";

    # Build bowtie command
    my $bowtie_cl = "bowtie $format -v $$options{'mismatches'} -p $$options{'bowtie_cores'} -S";
    if($$options{'mmap'} eq 'n') {
	$bowtie_cl .= " -a -m 1";
    } elsif ($$options{'bowtie_m'} =~ /^\d+$/) {
	$bowtie_cl .= " -a -m $$options{'bowtie_m'}";
    } else {
	$bowtie_cl .= " -a";
    }

    if($$options{'mismatches'} > 0) {
	$bowtie_cl .= " --best --strata";
    }
    if ($$cqual) {
	$bowtie_cl .= " -Q $$cqual";
    }
    if($format =~ /C/) {
	$bowtie_cl .= " --col-keepends";
    }

    if($$options{'g_type'} eq 'l') {
	$bowtie_cl .= " --large-index";
    }

    $bowtie_cl .= " --sam-RG ID:$base";
    $bowtie_cl .= " $ebwt_base -";
    if ($gz) {
	$bowtie_cl = "gzip -d -c $$reads | " . $bowtie_cl;
    } else {
	$bowtie_cl .= " < $$reads";
    }

    # Talk to user
    my $time = `date`;
    chomp $time;
    log_it($$options{'logfile'}, "\n$time");
    log_it($$options{'logfile'}, "Starting alignment of $$reads with bowtie command:\n\t$bowtie_cl");

    # Open file handles
    # If bowtie_cores is > 1 , need to use samtools sort to ensure output is sorted by read name .. pertinent for
    #  bowtie versions 1.2.0 and higher
    if($$options{'bowtie_cores'} > 1) {
	my $tempfile = $$options{'outdir'} . "\/" . $base . "_temp";
	open (SAM, "$bowtie_cl 2>> $$options{'error_logfile'} | samtools sort -n -O sam -m $$options{'sort_mem'} -T $tempfile - 2>> $$options{'error_logfile'} |");
    } else {
	open (SAM, "$bowtie_cl 2>> $$options{'error_logfile'} |");
    }
    open (OUT, "| gzip > $outfile");

    my $last_read = 'NULL';
    my @read_bucket = ();
    my $this_read;
    my $XX;
    my $fractional;
    my $flag;
    my $chr;
    my $left_pos;
    my $XM;
    my $bin;
    my $key;

    # counters
    my %counts = ();  ## keys: Uq, Mm, Xm, Um
    my $sum = 0;

    while(<SAM>) {
	if($_ =~ /^@/) {
	    print OUT $_;
	} else {
	    chomp;
	    $this_read = $_;
	    $this_read =~ s/\t.*//g;
	    if(($this_read ne $last_read) and ($last_read ne 'NULL')) {
		# Process the read bucket
		# Is it a singleton?
		if((scalar @read_bucket) == 1) {
		    # parse fields to see what type of singleton .. true unmapped, unmapped due to -m suppression, or unique mapper
		    if($read_bucket[0] =~ /^\S+\t(\d+)\t(\S+)\t(\d+)\t/) {
			$flag = $1;
			$chr = $2;
			$left_pos = $3;
			if($read_bucket[0] =~ /XM:i:(\d+)/) {
			    $XM = $1;
			} else {
			    $XM = -1;
			}
			if(($flag & 4) and ($XM > 0)) {
			    ## Suppressed b/c it was multi-mapped and run under --none
			    $read_bucket[0] .= "\tXX:i:-1";
			    ++$counts{'Xm'};
			    ++$sum;
			} elsif ($flag & 4) {
			    ## Truly unmappable
			    $read_bucket[0] .= "\tXX:i:0";
			    ++$counts{'Um'};
			    ++$sum;
			} else {
			    ## A unique mapper
			    $read_bucket[0] .= "\tXX:i:1";
			    ++$counts{'Uq'};
			    ++$sum;
			    ## Add to density hash, unless run under --none or --random
			    unless(($$options{'mmap'} eq 'n') or
				   ($$options{'mmap'} eq 'r')) {
				$bin = int ($left_pos / 50);
				$key = "$chr" . ":" . "$bin";
				++$$density{$key};
			    }
			}
			print OUT "$read_bucket[0]\n";
		    }
		} else {
		    # A multi-mapper. Need to process each of them
		    ++$counts{'Mm'};
		    ++$sum;
		    $XX = scalar @read_bucket;
		    foreach my $rb (@read_bucket) {
			$rb .= "\tXX:i:$XX";
			print OUT "$rb\n";
			# Add to density hash if mmap was set to f
			# $fractional will be one for unique mappers
			if($$options{'mmap'} eq 'f') {
			    $fractional = sprintf("%.4f", (1 / $XX));
			    if($rb =~ /^\S+\t\d+\t(\S+)\t(\d+)/) {
				$chr = $1;
				$left_pos = $2;
				$bin = int ($left_pos / 50);
				$key = "$chr" . ":" . "$bin";
				$$density{$key} += $fractional;
			    }
			}
		    }
		}
		# reset
		@read_bucket = ();
	    }
	    # add RG:Z tag
	    $_ .= "\tRG:Z:$base";

	    push(@read_bucket, $_);
	    $last_read = $this_read;
	}
    }
    close SAM;
    # close out the last read bucket.
    # Process the read bucket
    # Is it a singleton?
    if((scalar @read_bucket) == 1) {
	# parse fields to see what type of singleton .. true unmapped, unmapped due to -m suppression, or unique mapper
	if($read_bucket[0] =~ /^\S+\t(\d+)\t(\S+)\t(\d+)\t/) {
	    $flag = $1;
	    $chr = $2;
	    $left_pos = $3;
	    if($read_bucket[0] =~ /XM:i:(\d+)/) {
		$XM = $1;
	    } else {
		$XM = -1;
	    }
	    if(($flag & 4) and ($XM > 0)) {
		## Suppressed b/c it was multi-mapped and run under --none
		$read_bucket[0] .= "\tXX:i:-1";
		++$counts{'Xm'};
		++$sum;
	    } elsif ($flag & 4) {
		## Truly unmappable
		$read_bucket[0] .= "\tXX:i:0";
		++$counts{'Um'};
		++$sum;
	    } else {
		## A unique mapper
		$read_bucket[0] .= "\tXX:i:1";
		++$counts{'Uq'};
		++$sum;
		## Add to density hash, unless run under --none or --random
		unless(($$options{'mmap'} eq 'n') or
		       ($$options{'mmap'} eq 'r')) {
		    $bin = int ($left_pos / 50);
		    $key = "$chr" . ":" . "$bin";
		    ++$$density{$key};
		}
	    }
	    print OUT "$read_bucket[0]\n";
	}
    } else {
	# A multi-mapper. Need to process each of them
	++$counts{'Mm'};
	++$sum;
	$XX = scalar @read_bucket;
	foreach my $rb (@read_bucket) {
	    $rb .= "\tXX:i:$XX";
	    print OUT "$rb\n";
	    # Add to density hash if mmap was set to f
	    # $fractional will be one for unique mappers
	    if($$options{'mmap'} eq 'f') {
		$fractional = sprintf("%.4f", (1 / $XX));
		if($rb =~ /^\S+\t\d+\t(\S+)\t(\d+)/) {
		    $chr = $1;
		    $left_pos = $2;
		    $bin = int ($left_pos / 50);
		    $key = "$chr" . ":" . "$bin";
		    $$density{$key} += $fractional;
		}
	    }
	}
    }
    close OUT;

    # Squawk to user
    log_it($$options{'logfile'}, "\tCompleted. Results are in temporary file $outfile pending final processing");

    # Calculate and report on alignment types
    if(exists($counts{'Uq'})) {
	my $Ug_perc = sprintf("%.1f", (100*($counts{'Uq'} / $sum)));
	log_it($$options{'logfile'}, "\tUnique mappers: $counts{'Uq'} / $sum \($Ug_perc \%\)");
    }
    if(exists($counts{'Mm'})) {
	my $Mm_perc = sprintf("%.1f", (100*($counts{'Mm'} / $sum)));
	log_it($$options{'logfile'}, "\tMulti mappers: $counts{'Mm'} / $sum \($Mm_perc \%\)");
    }
    if(exists($counts{'Xm'})) {
	my $Xm_perc = sprintf("%.1f", (100*($counts{'Xm'} / $sum)));
	log_it($$options{'logfile'}, "\tMulti mappers ignored and marked as unmapped: $counts{'Xm'} / $sum \($Xm_perc \%\)");
    }
    if(exists($counts{'Um'})) {
	my $Um_perc = sprintf("%.1f", (100*($counts{'Um'} / $sum)));
	log_it($$options{'logfile'}, "\tNon mappers: $counts{'Um'} / $sum \($Um_perc \%\)");
    }

    return $outfile;
}

sub validate_mmap {
    my($options,$usage) = @_; ## references to hash, scalar
    if(exists($$options{'mmap'})) {
	unless(($$options{'mmap'} eq 'n') or
	       ($$options{'mmap'} eq 'u') or
	       #($$options{'mmap'} eq 'u2') or
	       ($$options{'mmap'} eq 'f') or
	       #($$options{'mmap'} eq 'f2') or
	       ($$options{'mmap'} eq 'r')) {
	    die "\nFatal: Option --mmap must be n, r, u, or f.\n$$usage\n";
	}
    } else {
	# If user did not specify, set the default
	$$options{'mmap'} = 'u';
    }
}

sub decider {
    my($options, $read_sorted_files, $density, $version_num, $command_line) = @_; ## passed by reference .. hash, array, hash, scalar, scalar
    my $time = `date`;
    chomp $time;
    log_it($$options{'logfile'}, "\n$time");
    log_it($$options{'logfile'}, "Processing and sorting alignments");
    # Initialize counters of XY calls
    my %XYs = ();
    $XYs{'N'} = 0;
    $XYs{'M'} = 0;
    $XYs{'U'} = 0;
    $XYs{'R'} = 0;
    $XYs{'P'} = 0;
    $XYs{'O'} = 0;
    # For each file separately, make decisions, and output to sorted files in the bam format
    my @bam_files = ();
    # First rs_file gets an @PG line added to the header. Occurs at the first non-header line of the first file
    my $needPG = 1;
    foreach my $rs_file (@$read_sorted_files) {
	log_it($$options{'logfile'}, "\tWorking on $rs_file");
	# parse file path of input file
	my($file,$path,$suffix) = fileparse($rs_file, qr/\.[^\.]+$/);
	# name the output file
	$file =~ s/_readsorted//g;
	$file =~ s/\.sam$//g;
	my $bam_file = "$path" . "$file" . ".bam";
	# name a temp file
	my $tempfile = "$path" . "$file" . "_temp";
	# open streams
	open(IN, "gzip -d -c $rs_file |");
	if(exists($$options{'sort_mem'})) {
		open(OUT, "| samtools view -u - | samtools sort -m $$options{'sort_mem'} -O bam -T $tempfile 2>> $$options{'error_logfile'} > $bam_file");
	} else {
	    open(OUT, "| samtools view -u - | samtools sort -O bam -T $tempfile 2>> $$options{'error_logfile'} > $bam_file");
	}

	# go line by line
	my $last_read = 'NULL';
	my $this_read;
	my @read_bucket = ();
	my $XZ;
	my $index;
	my $i;
	my @sam_fields = ();
	my $new_out;
	my @XZs = ();


	while (<IN>) {
	    chomp;
	    # headers pass through
	    if($_ =~ /^\@/) {
		print OUT $_, "\n";
	    } else {
		if ($needPG) {
		    print OUT "\@PG\tID:ShortStack\tVN:$$version_num\tCL:\"";
		    print OUT "$$command_line\"\n";
		    $needPG = 0;
		}
		if($_ =~ /^(\S+)\t/) {
		    $this_read = $1;
		    if(($this_read ne $last_read) and ($last_read ne 'NULL')) {
			# Process this read bucket.
			# If read bucket is size 1, it's either a unique mapper, truly unmapped, or unmapped due to -m
			# In any case, none will be flagged as secondary or otherwise processed
			# process read_bucket begins here
			if((scalar @read_bucket) == 1) {
			    if($read_bucket[0] =~ /XX:i:-1/) {
				# suppressed by -m
				$read_bucket[0] .= "\tXY:Z:M\tXZ:f:1";
				++$XYs{'M'};
			    } elsif ($read_bucket[0] =~ /XX:i:0/) {
				# truly unmappable
				$read_bucket[0] .= "\tXY:Z:N\tXZ:f:1";
				++$XYs{'N'};
			    } elsif ($read_bucket[0] =~ /XX:i:1/) {
				# unique mapper
				$read_bucket[0] .= "\tXY:Z:U\tXZ:f:1";
				++$XYs{'U'};
			    }
			    unless($$options{'keep_quals'}) {
				@sam_fields = split ("\t", $read_bucket[0]);
				$sam_fields[10] = '*';
				$read_bucket[0] = join ("\t", @sam_fields);
			    }
			    print OUT "$read_bucket[0]\n";
			} elsif ($$options{'mmap'} eq 'r') {
			    ## Read bucket is > 1, which means mmap could NOT have been n.
			    ++$XYs{'R'};
			    $XZ = sprintf("%.3f", (1 / (scalar @read_bucket)));
			    # designate one randomly
			    $index = int(rand(scalar @read_bucket));

			    if($$options{'show_secondaries'}) {
				for($i = 0; $i < (scalar @read_bucket); ++$i) {
				    @sam_fields = split ("\t", $read_bucket[$i]);
				    if($i == $index) {
					unless($$options{'keep_quals'}) {
					    $sam_fields[10] = '*';
					}
				    } else {
					$sam_fields[1] += 256; ## secondary alignment bit 0x100
					$sam_fields[9] = '*';  ## do not store SEQ on secondary alignments to save space
					$sam_fields[10] = '*'; ## do not store QUAL either
					$read_bucket[$i] = join("\t", @sam_fields);
				    }
				    # for randoms, all of em have the same XY and XZ tags
				    $read_bucket[$i] .= "\tXY:Z:R\tXZ:f:$XZ";
				    print OUT "$read_bucket[$i]\n";
				}
			    } else {
				# not showing secondaries
				@sam_fields = split ("\t", $read_bucket[$index]);
				unless($$options{'keep_quals'}) {
				    $sam_fields[10] = '*';
				}
				$read_bucket[$index] = join ("\t", @sam_fields);
				$read_bucket[$index] .= "\tXY:Z:R\tXZ:f:$XZ";
				print OUT "$read_bucket[$index]\n";
			    }
			} else {
			    ## If we get here, then mmap is f or u
			    ## Either way, use the density hash to get the odds of each read
			    pick_mmap($density,\@read_bucket,\%XYs,$options);
			    for($i = 0; $i < (scalar @read_bucket); ++$i) {
				print OUT "$read_bucket[$i]\n";
			    }
			}
			@read_bucket = ();
			# process read bucket ends here
		    }
		    push(@read_bucket, $_);
		    $last_read = $this_read;
		}
	    }
	}

	close IN;
	# Process the final read bucket
	# process read_bucket begins here
	if((scalar @read_bucket) == 1) {
	    if($read_bucket[0] =~ /XX:i:-1/) {
		# suppressed by -m
		$read_bucket[0] .= "\tXY:Z:M\tXZ:f:1";
		++$XYs{'M'};
	    } elsif ($read_bucket[0] =~ /XX:i:0/) {
		# truly unmappable
		$read_bucket[0] .= "\tXY:Z:N\tXZ:f:1";
		++$XYs{'N'};
	    } elsif ($read_bucket[0] =~ /XX:i:1/) {
		# unique mapper
		$read_bucket[0] .= "\tXY:Z:U\tXZ:f:1";
		++$XYs{'U'};
	    }
	    print OUT "$read_bucket[0]\n";
	} elsif ($$options{'mmap'} eq 'r') {
	    ## Read bucket is > 1, which means mmap could NOT have been n.
	    ++$XYs{'R'};
	    $XZ = sprintf("%.3f", (1 / (scalar @read_bucket)));
	    # designate one randomly
	    $index = int(rand(scalar @read_bucket));

	    if($$options{'show_secondaries'}) {
		for($i = 0; $i < (scalar @read_bucket); ++$i) {
		    @sam_fields = split ("\t", $read_bucket[$i]);
		    if($i == $index) {
			unless($$options{'keep_quals'}) {
			    $sam_fields[10] = '*';
			}
		    } else {
			$sam_fields[1] += 256; ## secondary alignment bit 0x100
			$sam_fields[9] = '*';  ## do not store SEQ on secondary alignments to save space
			$sam_fields[10] = '*'; ## do not store QUAL either
			$read_bucket[$i] = join("\t", @sam_fields);
		    }
		    # for randoms, all of em have the same XY and XZ tags
		    $read_bucket[$i] .= "\tXY:Z:R\tXZ:f:$XZ";
		    print OUT "$read_bucket[$i]\n";
		}
	    } else {
		# not showing secondaries
		@sam_fields = split ("\t", $read_bucket[$index]);
		unless($$options{'keep_quals'}) {
		    $sam_fields[10] = '*';
		}
		$read_bucket[$index] = join ("\t", @sam_fields);
		$read_bucket[$index] .= "\tXY:Z:R\tXZ:f:$XZ";
		print OUT "$read_bucket[$index]\n";
	    }
	} else {
	    ## If we get here, then mmap is f or u
	    ## Either way, use the density hash to get the odds of each read
	    pick_mmap($density,\@read_bucket,\%XYs,$options);
	    for($i = 0; $i < (scalar @read_bucket); ++$i) {
		print OUT "$read_bucket[$i]\n";
	    }
	}
	@read_bucket = ();

	# process read bucket ends here

	close OUT;

	# ensure file is not empty
	unless (-s $bam_file) {
	    log_it($$options{'logfile'}, "\nERROR - ABORTING. Processing and sorting of $rs_file failed. Check ErrorLog and settings of option --sort_mem");
	    exit;
	}

	push(@bam_files, $bam_file);
	# uncomment the line below after testing!
	system "rm -f $rs_file";
    }
    # Report on overall results
    my $XYtype;
    my $XYsum = 0;
    my $placed_sum = 0;
    while(($XYtype) = each %XYs) {
	$XYsum += $XYs{$XYtype};
	if(($XYtype eq 'U') or
	   ($XYtype eq 'R') or
	   ($XYtype eq 'P')) {
	    $placed_sum += $XYs{$XYtype};
	}
    }
    log_it($$options{'logfile'}, "Summary of primary alignments:");
    if($XYsum <= 0) {
	log_it($$options{'logfile'}, "\tNO alignments found. Aborting.");
	exit;
    } else {
	my $N_percent = sprintf("%.1f", 100 * ($XYs{'N'} / $XYsum));
	my $M_percent = sprintf("%.1f", 100 * ($XYs{'M'} / $XYsum));
	my $O_percent = sprintf("%.1f", 100 * ($XYs{'O'} / $XYsum));
	my $U_percent = sprintf("%.1f", 100 * ($XYs{'U'} / $XYsum));
	my $R_percent = sprintf("%.1f", 100 * ($XYs{'R'} / $XYsum));
	my $P_percent = sprintf("%.1f", 100 * ($XYs{'P'} / $XYsum));
	log_it($$options{'logfile'}, "\tXY:Z:N -- Unmapped because no valid alignments: $XYs{'N'} / $XYsum \($N_percent \%\)");
	log_it($$options{'logfile'}, "\tXY:Z:M -- Unmapped because alignment number exceeded option bowtie_m $$options{'bowtie_m'}: $XYs{'M'} / $XYsum \($M_percent \%\)");
	log_it($$options{'logfile'}, "\tXY:Z:O -- Unmapped because alignment number exceeded option ranmax $$options{'ranmax'} and no guidance was possible: $XYs{'O'} / $XYsum \($O_percent \%\)");
	log_it($$options{'logfile'}, "\tXY:Z:U -- Uniquely mapped: $XYs{'U'} / $XYsum \($U_percent \%\)");
	log_it($$options{'logfile'}, "\tXY:Z:R -- Multi-mapped with primary alignment chosen randomly: $XYs{'R'} / $XYsum \($R_percent \%\)");
	log_it($$options{'logfile'}, "\tXY:Z:P -- Multi-mapped with primary alignment chosen based on $$options{'mmap'}: $XYs{'P'} / $XYsum \($P_percent \%\)");
    }

    $$options{'total_primaries'} = $XYsum;
    $$options{'total_primaries_placed'} = $placed_sum;
    return @bam_files;
}

sub pick_mmap {
    my($density,$read_lines,$XYs,$options) = @_; ## references to hash, and array, and hash, and hash
    my $chr;
    my $left_pos;
    my $center_bin;
    my $bin_name;
    my @scores = ();
    my $score = 0;
    my $sum_scores = 0;
    my $line;


    foreach $line (@$read_lines) {
	if($line =~ /^\S+\t\d+\t(\S+)\t(\d+)\t/) {
	    $chr = $1;
	    $left_pos = $2;
	    $center_bin = int ($left_pos / 50);
	    $score = 0;
	    for(my $i = $center_bin -2; $i <= ($center_bin + 2); ++$i) {
		$bin_name = "$chr" . ":" . "$i";
		if(exists($$density{$bin_name})) {
		    $score += $$density{$bin_name};
		    $sum_scores += $$density{$bin_name};
		}
	    }
	    push(@scores, $score);
	    # TEST
	    #print STDERR "line $line\n";
	    #print STDERR "\tscore $score\n";
	    # END TEST
	}
    }

    # Are all scores the same? Either all zeroes OR all the same real number? If so, this
    # is just a random guess.
    my $all_scores_same = 1;
    for(my $x = 0; $x < ((scalar @scores) - 1); ++$x) {
	if($scores[$x] != $scores[($x + 1)]) {
	    $all_scores_same = 0;
	    last;
	}
    }


    my @XZs = ();
    my $XZ;
    my $XZr; ## rounded to 3 decimal places
    for(my $j = 0; $j < (scalar @$read_lines); ++$j) {
	if($sum_scores) {
	    $XZ = $scores[$j] / $sum_scores;
	    $XZr = sprintf("%.3f", $XZ);
	    push(@XZs, $XZ);
	    if($all_scores_same) {
		$$read_lines[$j] .= "\tXY:Z:R\tXZ:f:$XZr";
	    } else {
		$$read_lines[$j] .= "\tXY:Z:P\tXZ:f:$XZr";
	    }
	} else {
	    # Random
	    $XZ = 1 / (scalar @$read_lines);
	    $XZr = sprintf("%.3f", $XZ);
	    push(@XZs, $XZ);
	    $$read_lines[$j] .= "\tXY:Z:R\tXZ:f:$XZr";
	}
	# TEST
	#print STDERR "read_lines j $$read_lines[$j]\n";
	# END TEST
    }

    # Mark all but one as secondary alignments
    my $l;
    if(($all_scores_same) or ($sum_scores <= 0)) {
	## Ranmax violator?
	if($$options{'ranmax'} =~ /^\d+$/) {
	    if((scalar @XZs) > $$options{'ranmax'}) {
		$l = -1;
		++$$XYs{'O'};
	    } else {
		# randomly pick one
		++$$XYs{'R'};
		$l = int(rand(scalar @XZs));
	    }
	} else {
	    # randomly pick one
	    ++$$XYs{'R'};
	    $l = int(rand(scalar @XZs));
	}
    } else {
	## Can calculate a placement probability, so XY will be 'P'
	++$$XYs{'P'};

	#if($$options{'mmap'} =~ /1$/) {
	## placement method is probabilistic
	# generate a random number of 0 to less than 1
	my $rand_num = rand();
	my $cum_XZs = 0;
	# Find the first $l where $rand_num <= cumulative XZs
	for($l = 0; $l < (scalar @XZs); ++$l) {
	    $cum_XZs += $XZs[$l];
	    # TEST
	    #print STDERR "At l of $l cum_XZs is $cum_XZs and rand_num is $rand_num\n";
	    # END TEST
	    if($rand_num <= $cum_XZs) {
		last;
	    }
	}
	#} elsif ($$options{'mmap'} =~ /2$/) {
	    ## placement method is winner-take all
	 #   my $max = 0;
	 #   for(my $ll = 0; $ll < (scalar @XZs); ++$ll) {
	#	if($XZs[$ll] > $max) {
	#	    $max = $XZs[$ll];
	#	    $l = $ll;
	#	}
	#    }
	#}
    }
    # TEST
    #print STDERR "l set to $l\n";
    # END TEST

    # now, $l is set to be the chosen entry, or it is -1 indicating ranmax violator
    if($l == -1) {
	my @temp = ();
	push(@temp, $$read_lines[0]);
	$temp[0] =~ s/\tXY:Z:R/\tXY:Z:O/;
	my @ff = split ("\t", $temp[0]);
	if($ff[1] & 16) {
	    # need to flip the SEQ back to original
	    my $original = reverse $ff[9];
	    $original =~ tr/ACTG/TGAC/;
	    $ff[9] = $original;
	}
	$ff[1] = 4;  # FLAG set to unmapped
	$ff[2] = "\*";  # RNAME set to *
	$ff[3] = 0; ## per SAM spec for unmapped read
	$ff[4] = 0;
	$ff[5] = "*";
	$ff[6] = "*";
	$ff[7] = 0;
	$ff[8] = 0;
	unless($$options{'keep_quals'}) {
	    $ff[10] = '*';
	}
	my $temp_new = join("\t", @ff);
	$temp[0] = $temp_new;
	@$read_lines = @temp;
    } elsif ($$options{'show_secondaries'}) {
	for(my $k = 0; $k < (scalar @$read_lines); ++$k) {
	    # TEST
	    #print STDERR "at k $k read_lines is $$read_lines[$k]\n";
	    # END TEST
	    if($k == $l) {
		unless($$options{'keep_quals'}) {
		    my @fields = split ("\t", $$read_lines[$l]);
		    $fields[10] = '*';
		    $$read_lines[$l] = join("\t", @fields);
		}
	    } else {
		my @fields = split ("\t", $$read_lines[$k]);
		$fields[1] += 256; ## secondary alignment bit 0x100
		$fields[9] = '*';  ## do not store SEQ for secondary alignments IF a primary has been selected
		$fields[10] = '*'; ## do not store QUAL for secondary alignments IF a primary has been selected
		$$read_lines[$k] = join("\t", @fields);
	    }
	}
    } else {
	# not showing secondaries.
	unless($$options{'keep_quals'}) {
	    my @fields = split ("\t", $$read_lines[$l]);
	    $fields[10] = '*';
	    $$read_lines[$l] = join("\t", @fields);
	}
	my @temp = ();
	push(@temp, $$read_lines[$l]);
	@$read_lines = @temp;
    }
}

sub merge_bams {
    my($bams,$options) = @_;  ## references to array, hash
    my $merged_bam = "$$options{'outdir'}" . "\/" . "merged_alignments.bam";
    my $merge_command = "samtools merge $merged_bam";
    my $bam;
    foreach $bam (@$bams) {
	$merge_command .= " $bam";
    }
    my $time = `date`;
    chomp $time;
    log_it($$options{'logfile'}, "\n$time");
    log_it($$options{'logfile'}, "Merging files using the following samtools merge command:");
    log_it($$options{'logfile'}, "\t$merge_command");
    system "$merge_command 2>> $$options{'error_logfile'}";
    # verify file's existence at least
    unless(-r $merged_bam) {
	log_it($$options{'logfile'}, "\tABORT: after merging, expected file $merged_bam was not found.");
	exit;
    }
    # another thing to test ... what happens to @RG when merged? Need them to be maintained.

    # uncomment the lines below after testing
    foreach $bam (@$bams) {
	system "rm -f $bam";
    }

    return $merged_bam;
}

sub bam2cram {
    my($bam,$options) = @_; ## references to scalar, hash
    my $cramfile = $$bam;
    $cramfile =~ s/\.bam$/\.cram/;
    my $bam2cram_command = "samtools view -C -T $$options{'genomefile'} $$bam > $cramfile";
    my $time = `date`;
    chomp $time;
    log_it($$options{'logfile'}, "\n$time");
    log_it($$options{'logfile'}, "Converting alignment to cram format using samtools view command:");
    log_it($$options{'logfile'}, "\t$bam2cram_command");
    system "$bam2cram_command";   ## after testing, consider diercting STDERR to dev/null
    # verify file's existence
    unless(-r $cramfile) {
	log_it($$options{'logfile'}, "\tABORT: attempted conversion to cram failed .. could not read expected file $cramfile");
	exit;
    }
    # Uncomment the line below after testing
    system "rm -f $$bam";

    return $cramfile;
}

sub ensure_aln_idx {
    my($options) = @_; ## reference to the options hash
    my $expected_idx;
    if(exists($$options{'bamfile'})) {
	$expected_idx = "$$options{'bamfile'}" . ".bai";
	unless (-r $expected_idx) {
	    my $time = `date`;
	    chomp $time;
	    log_it($$options{'logfile'}, "\n$time");
	    log_it($$options{'logfile'}, "Required bamfile index $expected_idx not found. Attempting to create with samtools index.");
	    system "samtools index $$options{'bamfile'}";
	    unless (-r $expected_idx) {
		log_it($$options{'logfile'}, "FAILED - Aborting.");
		exit;
	    }
	}
    } elsif (exists($$options{'cramfile'})) {
	$expected_idx = "$$options{'cramfile'}" . ".crai";
	unless (-r $expected_idx) {
	    my $time = `date`;
	    chomp $time;
	    log_it($$options{'logfile'}, "\n$time");
	    log_it($$options{'logfile'}, "Required cramfile index $expected_idx not found. Attempting to create with samtools index.");
	    system "samtools index $$options{'cramfile'}";
	    unless (-r $expected_idx) {
		log_it($$options{'logfile'}, "FAILED - Aborting.");
		exit;
	    }
	}
    }
}

sub denovo {
    my($options) = @_; ## reference to options hash
    # Master controller for de novo cluster ID and parsing
    my $time = `date`;
    chomp $time;
    log_it($$options{'logfile'}, "\n$time");
    log_it($$options{'logfile'}, "Performing de-novo cluster identification and analyses.");

    # Task 1: Output f
    my $results_txt = "$$options{'outdir'}" . "\/Results.txt";
    open(RESULTS, ">$results_txt");

    # Add header to Results file
    print RESULTS "\#Locus\tName\tLength\tReads\tRPM\tUniqueReads\tFracTop\tStrand\tMajorRNA\tMajorRNAReads\t";
    print RESULTS "Complexity\tDicerCall\tMIRNA\tPhaseScore\tShort\tLong";
    for (my $dcs = $$options{'dicermin'}; $dcs <= $$options{'dicermax'}; ++$dcs) {
	print RESULTS "\t$dcs";
    }
    print RESULTS "\n";

    # get the names of the read-groups in the file (if any)
    my %read_groups = get_read_groups($options);  ## 'main' is ALWAYS defined.
    my $rg_count_file = "$$options{'outdir'}" . "\/Counts.txt";
    open(COUNTS, ">$rg_count_file");
    # Initialize the header of this file
    # If bam/cram has no read groups, rg is called 'main' by ShortStack
    initialize_rg_count_file(\%read_groups, \*COUNTS);

    # Determine threshold for discovery, converting to raw reads if necessary
    my $threshold;
    if($$options{'mincov'} =~ /^\d+$/) {
	$threshold = $&;
    } elsif ($$options{'mincov'} =~ /^([0-9]*\.[0-9]+|[0-9]+)(rpm{1,2})$/) {
	if($2 eq 'rpm') {
	    $threshold = 1 + int(($1 * $$options{'total_primaries'}) / 1E6);
	    log_it($$options{'logfile'}, "\n\tAt specified mincov of $$options{'mincov'} with $$options{'total_primaries'} primary reads,");
	    log_it($$options{'logfile'}, "\tmincov is $threshold raw alignments");
	} else {
	    # rpmm clause
	    $threshold = 1 + int(($1 * $$options{'total_primaries_placed'}) / 1E6);
	    log_it($$options{'logfile'}, "\n\tAt specified mincov of $$options{'mincov'} with $$options{'total_primaries_placed'} placed primary reads,");
	    log_it($$options{'logfile'}, "\tmincov is $threshold raw alignments");
	}
    }

    # If we are doing MIRNA finding, make a directory for those results.
    my $MIR_dir = "$$options{'outdir'}" . "\/MIRNAs";
    unless($$options{'nohp'}) {
	system "mkdir $MIR_dir";
    }

    # OK, let's do this
    if(exists($$options{'bamfile'})) {
	open(SAM, "samtools view -F 4 $$options{'bamfile'} |");
    } elsif (exists($$options{'cramfile'})) {
	open(SAM, "samtools view -F 4 $$options{'cramfile'} |");
    } else {
	log_it($$options{'logfile'}, "FATAL: Failed to open alignment file in sub-routine denovo.");
    }
    ### my @read_bucket;
    my $last_chr = 'NULL';
    my $last_right = -1 - $$options{'pad'};


    my @fields = ();
    my $read_length;

    my $open;
    my $right;

    my $cluster_n = 0;  ## for naming of the de-novo clusters
    my $cluster_name;

    my %all = (); ## primary reads ... {readgroup}{Chr\tleft\tSEQ\tstrand\tMDZ}
    my $all_tally = 0; ## total number of primaries across all read groups
    my $unq = 0; ## simple count of uniquely aligned primary reads across all read groups

    my $all_key;
    my $rg;
    my $is_unique;
    my $prob;
    my $mdz;

    my $illegals = 0;
    my $illegal;

    while (<SAM>) {
	@fields = split ("\t", $_);
	$illegal = check_illegal_CIGAR($fields[5]);
	if($illegal) {
	    ++$illegals;
	    next;
	}
	$fields[-1] =~ s/\n//g;
	$read_length = get_length_from_CIGAR($fields[5]);
	$right = $fields[3] + $read_length - 1;
	if($_ =~ /RG:Z:(\S+)/) {
	    if(exists($read_groups{$1})) {
		$rg = $1;
	    } else {
		$rg = 'main';
	    }
	} else {
	    $rg = 'main';
	}
	if($_ =~ /MD:Z:(\S+)/) {
	    $mdz = $1;
	} else {
	    $mdz = $read_length;
	}
	if($_ =~ /XY:Z:U/) {
	    $is_unique = 1;
	} else {
	    $is_unique = 0;
	}
	if($_ =~ /XZ:f:(\S+)/) {
	    $prob = $1;
	} elsif ($fields[1] & 256) {
	    $prob = 0; ## no other info and marked as secondary, prob is zero
	} else {
	    $prob = 1; ## no other info and NOT marked as secondary, prob is 1
	}

	# TEST
	# print STDERR "right: $right last_right: $last_right flag: $fields[1]\n";
	# END TEST

	if((($fields[2] ne $last_chr) and ($last_chr ne 'NULL')) or ($fields[3] >= ($$options{'pad'} + $last_right))) {
	    if($open) {
		# analyze
		# TEST
		#print STDERR "\tCaptured a locus:\n@read_bucket\n";
		#++$test;
		#if($test >= 50) {
		#    exit;
		#}
		# END TEST
		##### Initiate analysis block
		if($all_tally >= $threshold) {
		    ++$cluster_n;
		    $cluster_name = "Cluster_$cluster_n";
		    my($coords,$loc_size) = get_coords(\%all); ## based on 'main'
		    print RESULTS "$coords\t$cluster_name\t$loc_size";
		    print COUNTS "$coords\t$cluster_name";
		    analyze_locus($options, \*RESULTS, \*COUNTS, \%read_groups, \%all, \$unq, \$coords, \$loc_size, \$cluster_name);
		}
		##### End analysis block
	    }
	    # clear
	    $open = 0;
	    $last_right = -1 - $$options{'pad'};
	    %all = ();
	    $all_tally = 0;
	    $unq = 0;

	    # Process current read ... if it is a primary, open a new entry, process accordingly
	    unless($fields[1] & 256) {
		$open = 1;
		$last_right = $right;
		if($fields[1] & 16) {
		    $all_key = "$fields[2]" . "\t" . "$fields[3]" . "\t" . "$fields[9]" . "\t" . "\-" . "\t" . "$mdz";
		} else {
		    $all_key = "$fields[2]" . "\t" . "$fields[3]" . "\t" . "$fields[9]" . "\t" . "\+" . "\t" . "$mdz";
		}
		++$all{$rg}{$all_key};
		unless($rg eq 'main') {
		    ++$all{'main'}{$all_key};
		}
		++$all_tally;
		if($is_unique) {
		    ++$unq;
		}
	    }
	} else {
	    ## This clause ... must be the same chromosome, and at a proper distance
	    ## So, if open, keep current read no matter what, and store last_right if it's a primary alignment
	    if($open) {
		unless($fields[1] & 256) {
		    if($fields[1] & 16) {
			$all_key = "$fields[2]" . "\t" . "$fields[3]" . "\t" . "$fields[9]" . "\t" . "\-" . "\t" . "$mdz";
		    } else {
			$all_key = "$fields[2]" . "\t" . "$fields[3]" . "\t" . "$fields[9]" . "\t" . "\+" . "\t" . "$mdz";
		    }
		    ++$all{$rg}{$all_key};
		    unless($rg eq 'main') {
			++$all{'main'}{$all_key};
		    }
		    ++$all_tally;
		    if($is_unique) {
			++$unq;
		    }
		    $last_right = $right;
		}
	    } else {
		## ... or, if not open, open it if it is a primary
		unless($fields[1] & 256) {
		    $open = 1;
		    $last_right = $right;
		    if($fields[1] & 16) {
			$all_key = "$fields[2]" . "\t" . "$fields[3]" . "\t" . "$fields[9]" . "\t" . "\-" . "\t" . "$mdz";
		    } else {
			$all_key = "$fields[2]" . "\t" . "$fields[3]" . "\t" . "$fields[9]" . "\t" . "\+" . "\t" . "$mdz";
		    }
		    ++$all{$rg}{$all_key};
		    unless($rg eq 'main') {
			++$all{'main'}{$all_key};
		    }
		    ++$all_tally;
		    if($is_unique) {
			++$unq;
		    }

		    # TEST
		    # print STDERR "\tOpened and captured in second clause\n";
		    # END TEST
		}
	    }
	}
	$last_chr = $fields[2];
    }
    close SAM;

    if($illegals) {
	log_it($$options{'logfile'}, "\tWARNING: $illegals alignments were ignored due to illegal alignment types (gapped, spliced, clipped, or padded alignments are not accepted by ShortStack");
    }

#################################################

    # final bucket
    if($open) {
	##### Initiate analysis block
	if($all_tally >= $threshold) {
	    ++$cluster_n;
	    $cluster_name = "Cluster_$cluster_n";
	    my($coords,$loc_size) = get_coords(\%all);
	    print RESULTS "$coords\t$cluster_name\t$loc_size";
	    print COUNTS "$coords\t$cluster_name";
	    analyze_locus($options, \*RESULTS, \*COUNTS, \%read_groups, \%all, \$unq, \$coords, \$loc_size, \$cluster_name);
	}
	##### End analysis block
    }
    close RESULTS;

    ## Initiate search for unplaced RNAs
    $time = `date`;
    chomp $time;
    log_it($$options{'logfile'}, "Completed at $time");
    log_it($$options{'logfile'}, "\nPerforming search for unplaced small RNAs.");

    unplaced($options, \%read_groups, \*COUNTS, \$threshold);
    $time = `date`;
    chomp $time;
    log_it($$options{'logfile'}, "Completed at $time");

    close COUNTS;
}

sub analyze_locus {
    my($options, $res_fh, $cou_fh, $read_groups, $all, $unq, $coords, $loc_size, $loc_name) = @_;

    # first for main:
    my $observed;
    my $rg = 'main';
    my $observed_main = get_obs_from_all($all, \$rg);
    print $res_fh "\t$observed_main";
    print $cou_fh "\t$observed_main";

    # RPM
    my $rpm = sprintf("%.3f", 1E6 * ($observed_main / $$options{'total_primaries'}));
    print $res_fh "\t$rpm";

    # from the read groups separately
    my @rg_sorted = sort {$$read_groups{$a} <=> $$read_groups{$b}} keys %$read_groups;
    foreach $rg (@rg_sorted) {
	unless($rg eq 'main') {
	    $observed = get_obs_from_all($all, \$rg);
	    print $cou_fh "\t$observed";
	}
    }
    print $cou_fh "\n";

    # uniquely mapped count
    print $res_fh "\t$$unq";

    # top strand mappers and strand call
    my($frac_top,$strand_call) = get_strand($all,$options);
    print $res_fh "\t$frac_top\t$strand_call";

    # Dominant sequence, and complexity
    my($big_seq,$big_seq_n,$complexity) = get_big_seq($all);
    print $res_fh "\t$big_seq\t$big_seq_n\t$complexity";

    # DicerCall, and reads by length
    my %by_length = ();
    my $len;
    $by_length{'short'} = 0;
    $by_length{'long'} = 0;
    for($len = $$options{'dicermin'}; $len <= $$options{'dicermax'}; ++$len) {
	$by_length{$len} = 0;
    }
    my $dicer_ok = 0;
    my $dicer_n = 0;
    if(exists($$all{'main'})) {
	foreach my $mk (keys %{$$all{'main'}}) {
	    my @kf = split ("\t", $mk);
	    $len = length($kf[2]);
	    if($len < $$options{'dicermin'}) {
		$by_length{'short'} += $$all{'main'}{$mk};
		$dicer_n += $$all{'main'}{$mk};
	    } elsif ($len > $$options{'dicermax'}) {
		$by_length{'long'} += $$all{'main'}{$mk};
		$dicer_n += $$all{'main'}{$mk};
	    } else {
		$by_length{$len} += $$all{'main'}{$mk};
		$dicer_ok += $$all{'main'}{$mk};
	    }
	}
    }
    my $dicer_call = 'NA'; ## default if zero reads
    if(($dicer_ok) or ($dicer_n)) {
	if(($dicer_ok / ($dicer_ok + $dicer_n)) >= 0.8) {
	    ## set dicer_call to max size observed
	    my $d_max = 0;
	    for($len = $$options{'dicermin'}; $len <= $$options{'dicermax'}; ++$len) {
		if($by_length{$len} > $d_max) {
		    $dicer_call = $len;
		    $d_max = $by_length{$len};
		}
	    }
	} else {
	    $dicer_call = 'N';
	}
    }
    # print DicerCall here, save the by length until after MIRNA and phasing
    print $res_fh "\t$dicer_call";

    # MIRNA
    if($$options{'nohp'}) {
	print $res_fh "\tN0";
    } elsif ($observed_main == 0) {
	print $res_fh "\tN1";
    } elsif ($dicer_call =~ /[^\d]/) {
	print $res_fh "\tN2";
    } elsif ($big_seq_n < 2) {
	print $res_fh "\tN3";
    } elsif (((length $big_seq) < $$options{'dicermin'}) or ((length $big_seq) > $$options{'dicermax'})) {
	print $res_fh "\tN4";
    } elsif ($$loc_size > $$options{'foldsize'}) {
	print $res_fh "\tN5";
    } elsif ($strand_call =~ /[^\-\+]/) {
	print $res_fh "\tN6";
    } else {
	# Initiate MIRNA search
	my $mir_call = MIRNA($options,$all,$coords,\$strand_call,$loc_name);
	#my $mir_call = "Y";
	print $res_fh "\t$mir_call";
    }

    # Phasing
    if(($observed_main == 0) or
       ($dicer_call =~ /[^\d]/) or
       ($$loc_size < (3 * $dicer_call)) or
       ($strand_call =~ /[\-\+]/)) {
	print $res_fh "\t-1";
    } else {
	my $phase_score = phaser($all,$options,$coords,\$dicer_call);
	print $res_fh "\t$phase_score";
    }

    # print lengths .. short, long, DicerCalls
    print $res_fh "\t$by_length{'short'}\t$by_length{'long'}";
    for($len = $$options{'dicermin'}; $len <= $$options{'dicermax'}; ++$len) {
	print $res_fh "\t$by_length{$len}";
    }

    # Add a newline to the results file
    print $res_fh "\n";
}

sub phaser {
    # Based on modified version of equation 3 of Guo et al. (2015) doi:10.1093/bioinformatics/btu628
    my($all,$options,$coords,$dicer_call) = @_; ## references to 3 hashes and a scalar

    my $pr;
    my $pn;
    my $pa;
    my $score;

    my $size = $$dicer_call;

    my $loc_start;
    my %abun = ();
    my %distinct = ();

    my $fivep_corrected;
    my $k;
    my @kf = ();
    my $bin;

    my $sum = 0;
    my $rpm;
    my $rounded;

    # only check 21nt phasing for DicerCall 21 loci, and 24nt phasing for DicerCall 24 loci
    unless(($size == 21) or ($size == 24)) {
	$rounded = -1;
	return $rounded;
    }

    foreach $k (keys %{$$all{'main'}}) {
	@kf = split ("\t", $k);
	if($kf[3] eq '+') {
	    $fivep_corrected = $kf[1];
	} else {
	    $fivep_corrected = $kf[1] + 2;
	}
	$bin = $fivep_corrected % $size;  ## ranges from 0 to $size - 1.
	$abun{$bin} += $$all{'main'}{$k};
	++$distinct{$bin};
	$sum += $$all{'main'}{$k};
    }
    my @sorted = sort {$abun{$b} <=> $abun{$a}} keys %abun;
    # $sorted[0] is the best bin
    if($sum) {
	$pr = $abun{$sorted[0]} / $sum;
	$pn = $distinct{$sorted[0]};
	$rpm = 1E6 * ($abun{$sorted[0]} / $$options{'total_primaries'});
	$pa = log(1 + $rpm);   ### always add one to prevent low rpms (less then 1) to make a neg. number
	$score = $pr * $pn * $pa;
	$rounded = sprintf("%.1f", $score);
    } else {
	$rounded = -1;
    }
    return $rounded;
}



sub get_big_seq {
    my($all) = @_;  # reference to hash
    my $max_n = 0;
    my $max_seq = '*';
    my $sum = 0;
    my $n_seqs = 0;
    my $complexity = 'NA';
    if(exists($$all{'main'})) {
	foreach my $key (keys %{$$all{'main'}}) {
	    $sum += $$all{'main'}{$key};
	    ++$n_seqs;
	    if($$all{'main'}{$key} > $max_n) {
		$max_n = $$all{'main'}{$key};
		my @kf = split ("\t", $key);
		if($kf[3] eq '-') {
		    $max_seq = reverse (uc $kf[2]);
		    $max_seq =~ tr/ATUCG/UAAGC/;
		} else {
		    $max_seq = uc $kf[2];
		    $max_seq =~ s/T/U/g;
		}
	    }
	}
    }
    if($sum) {
	$complexity = sprintf("%.3f", ($n_seqs / $sum));
    }
    return($max_seq,$max_n,$complexity);
}


sub get_strand {
    my($all,$options) = @_; ## reference to hashes
    my $top = 0;
    my $sum = 0;
    my @keys = ();
    if(exists($$all{'main'})) {
	@keys = keys %{$$all{'main'}};
    }
    my $strand = 'NA';
    my $frac = 'NA';
    foreach my $key (@keys) {
	$sum += $$all{'main'}{$key};
	if($key =~ /\t\+\t/) {
	    $top += $$all{'main'}{$key};
	}
    }
    if($sum) {
	$frac = sprintf("%.3f", ($top / $sum));
	if($frac >= $$options{'strand_cutoff'}) {
	    $strand = "+";
	} elsif ($frac <= (1 - $$options{'strand_cutoff'})) {
	    $strand = "-";
	} else {
	    $strand = '.';
	}
    }
    return($frac,$strand);
}

sub get_obs_from_all {
    my($all, $rg) = @_;
    my $sum = 0;
    if(exists($$all{$$rg})) {
	#my @keys = keys $$all{$$rg};
	foreach my $key (keys %{$$all{$$rg}}) {
	    $sum += $$all{$$rg}{$key};
	}
    }
    return $sum;
}

sub get_mean_sd_from_resamples {
    my($resamples, $rg) = @_; # references to hash, scalar
    my $i;
    if(exists($$resamples{$$rg})) {
	my $sum = 0;
	for($i = 1; $i <= 10; ++$i) {
	    if(exists($$resamples{$$rg}{$i})) {
		$sum += $$resamples{$$rg}{$i};
	    }
	}
	my $mean = $sum / 10;
	my $sum_squares = 0;
	for($i = 1; $i <= 10; ++$i) {
	    if(exists($$resamples{$$rg}{$i})) {
		$sum_squares += ($$resamples{$$rg}{$i} - $mean) ** 2;
	    } else {
		$sum_squares += (0 - $mean) ** 2;
	    }
	}
	my $variance = $sum_squares / 10;
	my $stdev = sqrt($variance);
	# round to one decimal place
	my $mean_r = sprintf("%.1f", $mean);
	my $stdev_r = sprintf("%.1f", $stdev);
	return($mean_r,$stdev_r);
    } else {
	return ('NA', 'NA');
    }
}

sub get_coords {
    my($all) = @_; ## reference to hash
    my $min;
    my $max;
    my $chr;
    my $key;
    my @keys = keys %{$$all{'main'}};
    my $left;
    my $right;
    foreach $key (@keys) {
	my @kf = split ("\t", $key);
	$left = $kf[1];
	$right = (length $kf[2]) + $left - 1;
	if($min) {
	    if($left < $min) {
		$min = $left;
	    }
	} else {
	    $min = $left;
	}
	if($max) {
	    if($right > $max) {
		$max = $right;
	    }
	} else {
	    $max = $right;
	}
	$chr = $kf[0];
    }
    my $size = 'NA';
    my $coords = 'NA';
    if(($max) and ($min)) {
	$size = $max - $min + 1;
	$coords = "$chr" . ":" . "$min" . "-" . "$max";
    }
    return($coords,$size);
}

sub get_length_from_CIGAR {
    my($cigar) = @_;
    # length of read is sum of M/I/S/=/X operations, per the SAM spec
    my $read_length = 0;
    while($cigar =~ /(\d+)[MIS=X]/g) {
	$read_length += $1;
    }
    return $read_length;
}



sub get_read_groups {
    my($options) = @_; ## reference to options hash
    my %RG = ();
    $RG{'main'} = 1;
    if(exists($$options{'bamfile'})) {
	open(HEAD, "samtools view -H $$options{'bamfile'} |");
    } elsif (exists($$options{'cramfile'})) {
	open(HEAD, "samtools view -H $$options{'cramfile'} |");
    }
    my $i = 1;
    while (<HEAD>) {
	chomp;
	if($_ =~ /^\@RG.*ID:(\S+)/) {
	    ++$i;
	    $RG{$1} = $i;
	}
    }
    close HEAD;
    return %RG;  ## main has value of 1, others start at 2 and ascend (in order given by the header)
}

sub initialize_rg_count_file {
    my($read_groups, $fh) = @_; # references to hash and a file-handle
    print $fh "Locus\tName";
    my $i;
    my @sorted = sort {$$read_groups{$a} <=> $$read_groups{$b}} keys %$read_groups;
    foreach my $rg (@sorted) {
	print $fh "\t$rg";
    }
    print $fh "\n";
}

sub generate_counts {
    my($reads,$primaries,$name,$fh,$rgs) = @_; ## references to array, array, scalar, and file-handle, and array of read-group names
    # write name
    print $fh "$$name";

    my $main;
    my $count;
    my $i;

    if(@$rgs) {
	foreach my $rg (@$rgs) {
	    my @p_in_rg = get_in_rg($primaries,\$rg);
	    $main = scalar @p_in_rg;
	    print $fh "\t$main";
	    my @in_rg = get_in_rg($reads,\$rg);
	    for($i = 1; $i <= 9; ++$i) {
		$count = resample(\@in_rg);
		print $fh "\t$count";
	    }
	}
    } else {
	$main = scalar @$primaries;
	print $fh "\t$main";

	# Now, nine iterations.
	for($i = 1; $i <= 9; ++$i) {
	    $count = resample($reads);
	    print $fh "\t$count";
	}
    }
    print $fh "\n";
}

sub get_in_rg {
    my($reads,$rg) = @_; ## references to array and scalar
    my @out = ();
    foreach my $line (@$reads) {
	if($line =~ /\tRG:Z:(\S+)/) {
	    if($1 eq $$rg) {
		push (@out, $line);
	    }
	}
    }
    return @out;
}

sub resample {
    my($reads) = @_; # reference to array
    my $count = 0;
    if(@$reads) {
	foreach my $read (@$reads) {
	    if($read =~ /\tXZ:f:(\S+)/) {
		my $prob = $1;
		my $r = rand();
		if($r <= $prob) {
		    ++$count;
		}
	    } else {
		return 'NA';  ## if XZ:f is not set, can't re-sample
	    }
	}
    }
    return $count;
}

sub countmode {
    my($options) = @_;
    my $time = `date`;
    chomp $time;
    log_it($$options{'logfile'}, "\n$time");
    log_it($$options{'logfile'}, "Performing analysis of user indicated locus or loci.");

    # Task 1: Output f
    my $results_txt = "$$options{'outdir'}" . "\/Results.txt";
    open(RESULTS, ">$results_txt");

    # Add header to Results file
    print RESULTS "\#Locus\tName\tLength\tReads\tRPM\tUniqueReads\tFracTop\tStrand\tMajorRNA\tMajorRNAReads\t";
    print RESULTS "Complexity\tDicerCall\tMIRNA\tPhaseScore\tShort\tLong";
    for (my $dcs = $$options{'dicermin'}; $dcs <= $$options{'dicermax'}; ++$dcs) {
	print RESULTS "\t$dcs";
    }
    print RESULTS "\n";

    # get the names of the read-groups in the file (if any)
    my %read_groups = get_read_groups($options);  ## 'main' is ALWAYS defined.
    # my %rg_primaries = get_rg_primaries($options,\%read_groups);
    my $rg_count_file = "$$options{'outdir'}" . "\/Counts.txt";
    open(COUNTS, ">$rg_count_file");
    # Initialize the header of this file
    # If bam/cram has no read groups, rg is called 'main' by ShortStack
    initialize_rg_count_file(\%read_groups, \*COUNTS);

    # If we are doing MIRNA finding, make a directory for those results.
    my $MIR_dir = "$$options{'outdir'}" . "\/MIRNAs";
    unless($$options{'nohp'}) {
	system "mkdir $MIR_dir";
    }

    # Get the names and lengths of the chromosomes, per the header of the BAM/CRAM file
    my %chr_lens = get_chr_lens($options);

    # go for it
    my @count_loci = ();
    my @count_names = ();
    my $cidx;
    my $cn;
    if(exists($$options{'locus'})) {
	@count_loci = split (',', $$options{'locus'});
	for($cidx = 0; $cidx < (scalar @count_loci); ++$cidx) {
	    $cn = 1 + $cidx;
	    $count_names[$cidx] = "Cluster_$cn";
	}
    } elsif (exists($$options{'locifile'})) {
	open(C, "$$options{'locifile'}");
	$cidx = 0;
	while (<C>) {
	    chomp;
	    if($_ =~ /^\#/) {
		next;
	    }
	    my @cfields = split ("\t", $_);
	    if($cfields[0]) {
		++$cidx;
		$cn = 1 + $cidx;
		push(@count_loci, $cfields[0]);
		if($cfields[1]) {
		    push(@count_names, $cfields[1]);
		} else {
		    push(@count_names, "Cluster_$cn");
		}
	    }
	}
	close C;
    }
    my $illegal;
    my $illegals = 0;

    for($cidx = 0; $cidx < (scalar @count_loci); ++$cidx) {
	if($count_loci[$cidx] =~ /^(\S+):(\d+)-(\d+)$/) {
	    unless(exists($chr_lens{$1})) {
		log_it($$options{'logfile'}, "\tWARNING: Invalid locus query $count_loci[$cidx] : Chr is not defined in the alignment file per the SAM header : it is being ignored");
		next;
	    }
	    unless($2 > 0) {
		log_it($$options{'logfile'}, "\tWARNING: Invalid locus query $count_loci[$cidx] : Start has to be > 0 .. it is being ignored");
		next;
	    }
	    unless($3 > $2) {
		log_it($$options{'logfile'}, "\tWARNING: Invalid locus query $count_loci[$cidx] : Stop has to be > Start .. it is being ignored");
		next;
	    }
	    unless($3 <= $chr_lens{$1}) {
		log_it($$options{'logfile'}, "\tWARNING: Invalid locus query $count_loci[$cidx] : Stop is longer than the Chr length .. it is being ignored");
		next;
	    }

	    ## Analysis
	    ## Initialize data structures
	    my %all = (); ## primary reads ... {readgroup}{Chr\tleft\tSEQ\tstrand\tmdz} => frequency. main is always defined.
	    my $all_tally = 0; ## total number of primaries across all read groups
	    my $unq = 0; ## simple count of uniquely aligned primary reads across all read groups


	    my @fields = ();
	    my $read_length;
	    my $right;
	    my $rg;
	    my $is_unique;
	    my $prob;
	    my $all_key;
	    my $mdz;

	    # open SAM
	    if(exists($$options{'bamfile'})) {
		open(SAM, "samtools view $$options{'bamfile'} $count_loci[$cidx] |");
	    } elsif (exists($$options{'bamfile'})) {
		open(SAM, "samtools view $$options{'cramfile'} $count_loci[$cidx] |");
	    }

	    # read SAM, inputting data. Comparing to method denovo, any line here is in an 'open' cluster
	    while (<SAM>) {
		@fields = split("\t", $_);
		$illegal = check_illegal_CIGAR($fields[5]);
		if($illegal) {
		    ++$illegals;
		    next;
		}
		$read_length = get_length_from_CIGAR($fields[5]);
		$right = $fields[3] + $read_length - 1;
		if($_ =~ /RG:Z:(\S+)/) {
		    if(exists($read_groups{$1})) {
			$rg = $1;
		    } else {
			$rg = 'main';
		    }
		} else {
		    $rg = 'main';
		}
		if($_ =~ /MD:Z:(\S+)/) {
		    $mdz = $1;
		} else {
		    $mdz = $read_length;
		}
		if($_ =~ /XY:Z:U/) {
		    $is_unique = 1;
		} else {
		    $is_unique = 0;
		}
		if($_ =~ /XZ:f:(\S+)/) {
		    $prob = $1;
		} elsif ($fields[1] & 256) {
		    $prob = 0; ## no other info and marked as secondary, prob is zero
		} else {
		    $prob = 1; ## no other info and NOT marked as secondary, prob is 1
		}

		unless($fields[1] & 256) {
		    if($fields[1] & 16) {
			$all_key = "$fields[2]" . "\t" . "$fields[3]" . "\t" . "$fields[9]" . "\t" . "\-" . "\t" . "$mdz";
		    } else {
			$all_key = "$fields[2]" . "\t" . "$fields[3]" . "\t" . "$fields[9]" . "\t" . "\+" . "\t" . "$mdz";
		    }
		    ++$all{$rg}{$all_key};
		    unless($rg eq 'main') {
			++$all{'main'}{$all_key};
		    }
		    ++$all_tally;
		    if($is_unique) {
			++$unq;
		    }
		}
	    }
	    close SAM;
	    ### Analysis block begin
	    print RESULTS "$count_loci[$cidx]\t$count_names[$cidx]";
	    print COUNTS "$count_loci[$cidx]\t$count_names[$cidx]";
	    my $loc_size = 'NA';
	    if($count_loci[$cidx] =~ /^(\S+):(\d+)-(\d+)$/) {
		$loc_size = $3 - $2 + 1;
	    }
	    print RESULTS "\t$loc_size";
	    analyze_locus($options, \*RESULTS, \*COUNTS, \%read_groups, \%all, \$unq, \$count_loci[$cidx], \$loc_size, \$count_names[$cidx]);  ## must be robust to lack of any reads!

	} else {
	    log_it($$options{'logfile'}, "\tWARNING: Invalid locus query $count_loci[$cidx] : Format must be Chr:Start-Stop .. it is being ignored");
	    next;
	}
    }
    if($illegals) {
	log_it($$options{'logfile'}, "\tWARNING: $illegals alignments were illegal and were ignored. ShortStack considers gapped, spliced, clipped, and padded alignments illegal.");
    }
    close RESULTS;
    close COUNTS;
}

sub get_chr_lens {
    my($options) = @_;  ## reference to hash
    my %hash = ();
    if(exists($$options{'bamfile'})) {
	open(HEAD, "samtools view -H $$options{'bamfile'} |");
    } elsif (exists($$options{'cramfile'})) {
	open(HEAD, "samtools view -H $$options{'cramfile'} |");
    }
    my $chr;
    my $len;
    while (<HEAD>) {
	$chr = '';
	$len = '';
	chomp;
	if($_ =~ /^\@SQ/) {
	    if($_ =~ /SN:(\S+)/) {
		$chr = $1;
	    }
	    if($_ =~ /LN:(\d+)/) {
		$len = $1;
	    }
	    if(($chr) and ($len)) {
		$hash{$chr} = $len;
	    }
	}
    }
    close HEAD;
    return %hash;
}

sub MIRNA {
    my($options,$all,$coords,$strand,$loc_name) = @_;
    # references to hash, hash, scalar, scalar, and scalar

    # parse locus size, expand to the specified size for the folding region
    my $loc_size;
    my $loc_center;
    my $chr;
    if($$coords =~ /^(\S+):(\d+)-(\d+)$/) {
	$chr = $1;
	$loc_size = $3 - $2 + 1;
	$loc_center = $2 + int (0.5 * $loc_size);
    }
    my $fold_start = $loc_center - (int(0.5 * $$options{'foldsize'}));
    my $fold_stop = $loc_center + (int(0.5 * $$options{'foldsize'}));
    if($fold_start < 1) {
	$fold_start = 1;
    }
    my $faidx_region_o = "$chr" . ":" . "$fold_start" . "-" . "$fold_stop";  # _o is for original
    my $faidx_region_s;  ## _s is for stitched, should it exist
    if(exists($$options{'stitchgenomefile'})) {
	$faidx_region_s = convert_coordinates($options,\$faidx_region_o);
	# test
	#print "\nReturned converted coordinates for $faidx_region_o as $faidx_region_s\n";
	#exit;
    }
    # TEST
    #print "Locus: $$coords Strand: $$strand Folded Region: $faidx_region\n";
    # END TEST

    # get sequence to be folded
    my $fold_seq;
    if($faidx_region_s) {
	$fold_seq = get_fold_seq($options,$strand,\$faidx_region_s);
    } else {
	$fold_seq = get_fold_seq($options,$strand,\$faidx_region_o);
    }
    # TEST
    #print "$fold_seq : fold_seq\n";
    # END TEST

    # fold the query
    my $brax = get_brax(\$fold_seq, $options);
    unless($brax) {
	# TEST
	#print "failed get_brax\n\n";
	# END TEST
	return 'N7';
    }

    # TEST
    #print "$brax : brax\n";
    # END TEST

    # key of the candidate mature miRNA
    my ($mirkey,$locus_sum) = get_mir_key($all,$strand);  ## note that the reference to strand here is the strand of the folded region.
    unless($locus_sum) {
	# TEST
	#print "failed get_mir_key\n\n";
	# END TEST
	return $mirkey;
    }

    # TEST
    #print "mirkey: $mirkey locus_sum: $locus_sum\n";
    # END TEST

    # mature miRNA pairing .. all 'one way', 4 or fewer unpaired bases
    # no more than one bulge containing no more than 2 bulged nts.
    # faidx region should always be _o here
    my $star_key = check_mir_star($brax,$mirkey,$faidx_region_o);  ## returns 0 if fail, or key in form Chr\tleft\tx\tstrand\tlength
    if ($star_key =~ /^N\d+$/) {
	# TEST
	#print "failed check_mir_star\n\n";
	# END TEST
	return $star_key;
    }

    # TEST
    #print "Locus: $$coords Strand: $$strand Folded Region: $faidx_region\n";
    #print "$fold_seq : fold_seq\n";
    #print "$brax : brax\n";
    #print "mirkey: $mirkey locus_sum: $locus_sum\n";
    #print "star_key: $star_key\n";


    # END TEST

    # If we got here, now check for star having been sequenced
    # Along the way, count the miRNA 3p variants and star-3p variants
    my $star_count = 0;
    my $real_star_key;
    my @sk = split ("\t", $star_key);
    my @as = ();
    my $mir_3pv = 0;
    my $star_3pv = 0;

    my $mir_fivep = get_fivep($mirkey);
    my $star_fivep = get_fivep($star_key);

    my $this_fivep;

    foreach my $ak (keys %{$$all{'main'}}) {
	# has to match chr, left, strand, and have the SEQ be same length as in mdz of star_key
	@as = split ("\t", $ak);
	if(($sk[0] eq $as[0]) and
	   ($sk[1] == $as[1]) and
	   ($sk[3] eq $as[3]) and
	   ($sk[4] == (length $as[2]))) {
	    if($$all{'main'}{$ak} > $star_count) {
		$star_count = $$all{'main'}{$ak};
		$real_star_key = $ak;
	    }
	}
    }
    foreach my $ak (keys %{$$all{'main'}}) {
	# has to match chr, left, strand, and have the SEQ be same length as in mdz of star_key
	if($ak eq $mirkey) {
	    next;
	}
	if($real_star_key) {
	    if($ak eq $real_star_key) {
		next;
	    }
	}
	$this_fivep = get_fivep($ak);
	if($this_fivep == $mir_fivep) {
	    $mir_3pv += $$all{'main'}{$ak};
	} elsif ($this_fivep == $star_fivep) {
	    $star_3pv += $$all{'main'}{$ak};
	}
    }


    # TEST
    #print "star_count: $star_count mir count: $$all{'main'}{$mirkey}\n";
    # END TEST

    # mature, star, and their 3p variants must total >= 50% of the reads
    unless(($star_count + $$all{'main'}{$mirkey} + $mir_3pv + $star_3pv) >= (0.5 * $locus_sum)) {
	# TEST
	#print "failed 50 percent test\n\n";
	# END TEST
	return 'N14';
    }

    # Display
    my $call;


    # Fully validated if the star was sequenced. If not, gets an 'N15'
    if($star_count) {
	# TEST
	#print "result: Y\n\n";
	## END TEST
	$call = 'Y';
	plain_text($all,\$mirkey,\$star_key,$options,$strand,\$faidx_region_o,$coords,$loc_name,\$fold_seq,\$brax,\$call,\$real_star_key);
	return 'Y';
    } else {
	# TEST
	#print "result: M\n\n";
	# END TEST
	# NO MORE M
        #$call = 'M';
	#plain_text($all,\$mirkey,\$star_key,$options,$strand,\$faidx_region,$coords,$loc_name,\$fold_seq,\$brax,\$call,\$real_star_key);
	return 'N15';
    }
}

sub check_mir_star {
    my($brax,$mirkey,$fold_locus) = @_;
    # parse strand
    my @mk = split ("\t", $mirkey);
    my $strand = $mk[3];
    # find corresponding brax
    my $offset;
    my $chr;
    my $fold_start;
    my $fold_stop;
    if($fold_locus =~ /^(\S+):(\d+)-(\d+)$/) {
	$chr = $1;
	$fold_start = $2;
	$fold_stop = $3;
    } else {
	return 'N10';
    }
    if($strand eq '+') {
	$offset = $mk[1] - $fold_start;
    } else {
	$offset = $fold_stop - $mk[1] - (length $mk[2]) + 1;
    }
    unless (($offset + (length $mk[2])) < (length $brax)) {
	return 'N10';
    }

    my $mir_brax = substr($brax,$offset,(length $mk[2]));

    my $n_mir_up = 0;
    while ($mir_brax =~ /\./g) {
	++$n_mir_up;
    }
    if($n_mir_up > 5) {
	return 'N11';
    }

    my $last_right;
    my $last_left;
    my $n_bulges = 0;
    my $bulged_nts = 0;
    my $left_delta;
    my $right_delta;
    my $star_brax_end;
    my $star_brax_start;

    if($mir_brax =~ /^[\.\(]+$/) {
	# find star of a 5p miRNA
	my %left_right = get_lr($brax);

	# get one-based start and stop of the mature miRNA, relative to brax
	my $mir_brax_start = $offset + 1;
	my $mir_brax_end = $mir_brax_start + (length $mk[2]) - 1;
	my $left;

	# March through the mature miRNA until the last 2 bases (3' overhang),
	# tracking bulges, and getting the star 5p and 3p
	for($left = $mir_brax_start; $left <= ($mir_brax_end - 2); ++$left) {
	    if(exists($left_right{$left})) {
		if(($last_right) and ($last_left)) {
		    # was it a bulge?
		    $left_delta = $left - $last_left;
		    $right_delta = $last_right - $left_right{$left};
		    if(abs($left_delta - $right_delta)) {
			++$n_bulges;
			$bulged_nts += abs($left_delta - $right_delta);
		    }
		} else {
		    # This is the first pair found in the duplex
		    # Infer the 3p end of the miRNA* .. 2nt offset
		    $star_brax_end = $left_right{$left} + 2 + ($left - $mir_brax_start);
		}
		$last_left = $left;
		$last_right = $left_right{$left};
	    }
	}
	if(($n_bulges > 2) or ($bulged_nts > 3)) {
	    return 'N13';
	} else {
	    unless($last_left) {
		return 'N10';
	    }
	    # Calculate the star 5p position, relative to brax
	    $star_brax_start = $left_right{$last_left} - (($mir_brax_end - 2) - $last_left);
	    # above, the right-hand term is 0 if the last position analyzed of the mature miRNA was paired.

	    ## encode and return (below)
	}
    } elsif ($mir_brax =~ /^[\.\)]+$/) {
	# find star of a 3p miRNA
	my %right_left = get_rl($brax);

	# get one-based start and stop of the mature miRNA, relative to brax
	my $mir_brax_start = $offset + 1;
	my $mir_brax_end = $mir_brax_start + (length $mk[2]) - 1;
	my $right;

	# March through the mature miRNA until the last 2 bases (3' overhang),
	# tracking bulges, and getting the star 5p and 3p
	for($right = $mir_brax_start; $right <= ($mir_brax_end - 2); ++$right) {
	    if(exists($right_left{$right})) {
		if(($last_right) and ($last_left)) {
		    # was it a bulge?
		    $left_delta = $right_left{$right} - $last_left;
		    $right_delta = $last_right - $right;
		    if(abs($left_delta - $right_delta)) {
			++$n_bulges;
			$bulged_nts += abs($left_delta - $right_delta);
		    }
		} else {
		    # This is the first pair found in the duplex
		    # Infer the 3p end of the miRNA* .. 2nt offset
		    $star_brax_end = $right_left{$right} + ($right - $mir_brax_start) + 2;
		}
		$last_left = $right_left{$right};
		$last_right = $right;
	    }
	}
	if(($n_bulges > 2) or ($bulged_nts > 3)) {
	    return 'N13';
	} else {
	    unless($last_right) {
		return 'N10';
	    }
	    # Calculate the star 5p position, relative to brax
	    $star_brax_start = $right_left{$last_right} - (($mir_brax_end - 2) - $last_right);
	    # above, the right-hand term is 0 if the last position of the mature miRNA was paired.
	}
    } else {
	## mature miRNA had mixed pairing
	return 'N12';
    }

    # convert the star coordinates
    if(($star_brax_start) and ($star_brax_end)) {
	if($star_brax_start >= $star_brax_end) {
	    return 'N10';
	} else {
	    # encode
	    my $star_key = "$mk[0]" . "\t";
	    my $star_left;
	    if($strand eq '+') {
		$star_left = $star_brax_start + $fold_start - 1;
	    } else {
		$star_left = $fold_stop - $star_brax_end + 1;
	    }
	    $star_key .= "$star_left" . "\t" . "x" . "\t" . "$strand" . "\t";
	    my $mdz = $star_brax_end - $star_brax_start + 1;  ## just the length
	    $star_key .= "$mdz";
	    return $star_key;
	}
    } else {
	return 'N10';
    }
}

sub get_rl {
    my($brax) = @_;
    my %lr = get_lr($brax);
    my %rl = ();
    my $left;
    my $right;
    while(($left,$right) = each %lr) {
	$rl{$right} = $left;
    }
    return %rl;
}

sub get_lr {
    my($brax) = @_;
    my %hash = ();
    my @char = split ('',$brax);
    my @lefts = ();
    my $i = 0;
    my $left;
    foreach my $ch (@char) {
	++$i;
	if($ch eq "\(") {
	    push(@lefts,$i);
	} elsif ($ch eq "\)") {
	    $left = pop @lefts;
	    $hash{$left} = $i;
	}
    }
    return %hash;
}





sub get_mir_key {
    my($all,$folded_strand) = @_; ## references to hash, scalar
    my @keys = keys %{$$all{'main'}};
    my $max_n = 0;
    my $max_key;
    my $sum = 0;
    foreach my $key (@keys) {
	if($$all{'main'}{$key} > $max_n) {
	    $max_key = $key;
	    $max_n = $$all{'main'}{$key};
	}
        $sum += $$all{'main'}{$key};
    }
    if($max_key) {
	my @mk = split ("\t", $max_key);
	if($mk[3] eq $$folded_strand) {
	    return ($max_key, $sum);
	} else {
	    return 'N8';
	}
    } else {
	return 'N9';
    }
}

sub get_fold_seq {
    my($options,$strand,$region) = @_; ## references to hash, scalar, and scalar
    if(exists($$options{'stitchgenomefile'})) {
	open(FASTA, "samtools faidx $$options{'stitchgenomefile'} $$region |");
    } else {
	open(FASTA, "samtools faidx $$options{'genomefile'} $$region |");
    }
    my $raw_seq;
    while (<FASTA>) {
	if($_ =~ /^>/) {
	    next;
	} else {
	    chomp;
	    $raw_seq .= uc $_;
	}
    }
    close FASTA;
    # change T to U
    $raw_seq =~ s/T/U/g;
    my $seq;
    if($$strand eq '-') {
	$seq = reverse $raw_seq;
	$seq =~ tr/AUCG/UAGC/;
    } else {
	$seq = $raw_seq;
    }
    return $seq;
}

sub check_illegal_CIGAR {
    my($cigar) = @_;
    if($cigar =~ /[^\dM\=X]/) {
	return 1;
    } else {
	return 0;
    }
}

sub get_brax {
    my($seq, $options) = @_;  ## references to scalar, hash
    if($$options{'RNAfold_version'} == 1) {
	open(RNAF, "echo $$seq | RNAfold -noPS |");
    } else {
	open(RNAF, "echo $$seq | RNAfold --noPS |");
    }
    my @rnaf = <RNAF>;
    close RNAF;
    if($rnaf[1]) {
	my $brax = $rnaf[1];
	$brax =~ s/\s.*$//g;
	$brax =~ s/\n//g;
	return $brax;
    } else {
	return 0;
    }
}

sub plain_text {
    my($all,$mirkey,$star_key,$options,$strand,$fold_region,$loc_region,$loc_name,$fold_seq,$brax,$call,$real_star_key) = @_;
    # references to hash, scalar, scalar, hash, and the rest scalars

    # trim the displayed region, if possible.
    # 20nts flanking all expressed reads, and the computed miR*
    my ($trim_region,$trim_seq,$trim_brax) = get_trim_region($mirkey,$star_key,$strand,$fold_region,$fold_seq,$brax);

    # open file
    my $pt_file = "$$options{'outdir'}" . "\/MIRNAs\/$$loc_name" . "_$$call" . "\.txt";
    open(PT, ">$pt_file");
    print PT "$$loc_name Original Location: $$loc_region Displayed Location: $trim_region Strand: $$strand\n";
    #if($$call eq 'M') {
	#print PT "WARNING: miRNA-star NOT observed. These data alone do NOT support a de-novo annotation of this locus as a MIRNA.\n\n";
    #} else {
    print PT "\n";
    #}
    print PT "$trim_seq\n";
    print PT "$trim_brax\n";


    my $chr;
    my $fold_start;
    my $fold_stop;
    if($trim_region =~ /^(\S+):(\d+)-(\d+)$/) {
	$chr = $1;
	$fold_start = $2;
	$fold_stop = $3;
    } else {
	return 0;
    }
    my @lines = ();
    my @kf = ();
    my $i;
    my $line;

    my $read_len;
    my $lc_seq;


    ## Begin with the mature miRNA and the star
    @kf = split ("\t", $$mirkey);
    for($i = $fold_start; $i < $kf[1]; ++$i) {
	$line .= '.';
    }
    $lc_seq = lc_from_mdz($kf[2],$kf[-1]);
    $lc_seq =~ s/T/U/g;
    $lc_seq =~ s/t/u/g;
    $line .= $lc_seq;
    for($i = ($kf[1] + (length $kf[2])); $i <= $fold_stop; ++$i) {
	$line .= '.';
    }
    if($$strand eq '-') {
	my $rc_line = reverse $line;
	$rc_line =~ tr/AUCG/UAGC/;
	$line = $rc_line;
    }
    $read_len = length $kf[2];
    $line .= " miRNA l=$read_len a=$$all{'main'}{$$mirkey}\n";
    print PT "$line";

    $line = '';

    if($$real_star_key) {
	@kf = split ("\t", $$real_star_key);
    } else {
	@kf = split ("\t", $$star_key);
    }
    for($i = $fold_start; $i < $kf[1]; ++$i) {
	$line .= '.';
    }

    if($$real_star_key) {
	$lc_seq = lc_from_mdz($kf[2],$kf[-1]);
	$lc_seq =~ s/T/U/g;
	$lc_seq =~ s/t/u/g;
	$line .= $lc_seq;
	$read_len = length $lc_seq;
    } else {
	$read_len = 0;
	for($i = 1; $i <= $kf[-1]; ++$i) {
	    $line .= 'X';
	    ++$read_len;
	}
    }

    for($i = ($kf[1] + $read_len); $i <= $fold_stop; ++$i) {
	$line .= '.';
    }
    if($$strand eq '-') {
	my $rc_line = reverse $line;
	$rc_line =~ tr/AUCG/UAGC/;
	$line = $rc_line;
    }
    $line .= " miRNA-star l=$read_len a=";
    if($$real_star_key) {
	$line .= "$$all{'main'}{$$real_star_key}\n";
    } else {
	$line .= "0\n";
    }
    print PT "$line";
    print PT "\n";
    ## Now, all other reads that are not the miRNA or the star. PROVIDED that they are fully within the displayed interval.

    foreach my $k (keys %{$$all{'main'}}) {
	if($k eq $$mirkey) {
	    next;
	}
	if($$real_star_key) {
	    if($k eq $$real_star_key) {
		next;
	    }
	}
	$line = '';
	@kf = split ("\t", $k);

	# kf[1] must be >= fold_start and kf[1] + length kf[2] - 1 must be <= fold_stop
	if(($kf[1] < $fold_start) or
	   (($kf[1] + (length $kf[2])) > $fold_stop)) {
	    next;
	}
	for($i = $fold_start; $i < $kf[1]; ++$i) {
	    if($$strand ne $kf[3]) {
		$line .= '<';
	    } else {
		$line .= '.';
	    }
	}

	$lc_seq = lc_from_mdz($kf[2],$kf[-1]);  ## positions mismatching reference will be changed to lower-case
	$lc_seq =~ s/T/U/g;
	$lc_seq =~ s/t/u/g;
	if($kf[3] ne $$strand) {
	    $lc_seq =~ tr/ACTUGactug/UGAACugaac/;
	}
	$line .= $lc_seq;
	for($i = ($kf[1] + (length $kf[2])); $i <= $fold_stop; ++$i) {
	    if($$strand ne $kf[3]) {
		$line .= '<';
	    } else {
		$line .= '.';
	    }
	}
	if($$strand eq '-') {
	    my $rc_line = reverse $line;
	    $rc_line =~ tr/AUCGaucg/UAGCuagc/;
	    $rc_line =~ s/\>/\</g;
	    $line = $rc_line;
	}
	$read_len = length $kf[2];
	$line .= " l=$read_len a=$$all{'main'}{$k}\n";
	push(@lines, $line);
    }
    my @lines_s = sort @lines;
    foreach $line (@lines_s) {
	print PT "$line";
    }
    print PT "\n";
    close PT;
}

sub lc_from_mdz {
    my($raw_seq,$mdz) = @_;
    my $raw2_seq = uc $raw_seq; ## just in case
    # easy case .. no mismatches
    if($mdz =~ /^\d+$/) {
	return $raw2_seq;
    } else {
	my %mms = ();
	my $pos = 0;
	my $i;
	while($mdz =~ /([0-9]+)([A-Z]+)/g) {
	    for($i = 1; $i <= $1; ++$i) {
		++$pos;
	    }
	    my @bad_l = split ('', $2);
	    foreach my $bad (@bad_l) {
		++$pos;
		$mms{$pos} = 1;
	    }
	}
	my $lc_seq;
	my @letters = split('', $raw2_seq);
	my $add;
	$i = 0;
	foreach my $l (@letters) {
	    ++$i;
	    if(exists($mms{$i})) {
		$add = lc $l;
	    } else {
		$add = $l;
	    }
	    $lc_seq .= $add;
	}
	return $lc_seq;
    }
}

sub get_trim_region {
    my($mirkey,$star_key,$strand,$fold_region,$fold_seq,$brax) = @_;
    # references to scalars
    my $fold_chr;
    my $fold_start;
    my $fold_stop;
    if($$fold_region =~ /^(\S+):(\d+)-(\d+)$/) {
	$fold_chr = $1;
	$fold_start = $2;
	$fold_stop = $3;
    } else {
	return 0;
    }
    my $smallest;
    my $largest;
    my @kf = ();

    # mirkey
    @kf = split ("\t", $$mirkey);
    if($smallest) {
	if($kf[1] < $smallest) {
	    $smallest = $kf[1];
	}
    } else {
	$smallest = $kf[1];
    }
    my $mir_length;
    if($kf[-1] =~ /^\d+$/) {
	$mir_length = $kf[-1];
    } else {
	$mir_length = get_len_from_mdz($kf[-1]);
    }
    my $end = $mir_length + $kf[1] - 1;
    if($largest) {
	if($end > $largest) {
	    $largest = $end;
	}
    } else {
	$largest = $end;
    }

    # the computed star key also gets considered here.
    @kf = split ("\t", $$star_key);
    if($smallest) {
	if($kf[1] < $smallest) {
	    $smallest = $kf[1];
	}
    } else {
	$smallest = $kf[1];
    }
    my $star_len;
    if($kf[-1] =~ /^\d+$/) {
	$star_len = $kf[-1];
    } else {
	$star_len = get_len_from_mdz($kf[-1]);
    }
    $end = $star_len + $kf[1] - 1;
    if($largest) {
	if($end > $largest) {
	    $largest = $end;
	}
    } else {
	$largest = $end;
    }

    my $trim_start;
    my $trim_stop;

    if(($smallest - 20) < $fold_start) {
	$trim_start = $fold_start;
    } elsif (($smallest - 20) >= 1) {
	$trim_start = ($smallest - 20);
    } else {
	$trim_start = 1;
    }


    if(($largest + 20) > $fold_stop) {
	$trim_stop = $fold_stop;
    } else {
	$trim_stop = ($largest + 20);
    }

    my $trim_region = "$fold_chr" . ":" . "$trim_start" . "-" . "$trim_stop";

    # identical?
    if($trim_region eq $$fold_region) {
	return($trim_region,$$fold_seq,$$brax);
    } else {
	my $o_brax;
	my $o_seq;
	if($$strand eq '-') {
	    $o_brax = reverse $$brax;
	    $o_seq = reverse $$fold_seq;
	} else {
	    $o_brax = $$brax;
	    $o_seq = $$fold_seq;
	}
	my $offset = $trim_start - $fold_start;
	my $len = $trim_stop - $trim_start + 1;
	my $o2_brax = substr($o_brax,$offset,$len);
	my $o2_seq = substr($o_seq,$offset,$len);

	my $o3_brax;
	my $o3_seq;
	if($$strand eq '-') {
	    $o3_brax = reverse $o2_brax;
	    $o3_seq = reverse $o2_seq;
	} else {
	    $o3_brax = $o2_brax;
	    $o3_seq = $o2_seq;
	}
	return($trim_region,$o3_seq,$o3_brax);
    }
}

sub get_len_from_mdz {
    my($mdz) = @_;
    my $len = 0;
    my $i;
    while($mdz =~ /([0-9]+)([A-Z]+)/g) {
	for($i = 1; $i <= $1; ++$i) {
	    ++$len;
	}
    }
    return $len;
}


sub get_fivep {
    my($key) = @_;
    my @fields = split ("\t", $key);
    if($fields[3] eq '+') {
	return $fields[1];
    } else {
	my $len = 0;
	while ($fields[-1] =~ /\d+/g) {
	    $len += $&;
	}
	while ($fields[-1] =~ /\D/g) {
	    ++$len;
	}
	my $out = $fields[1] + $len - 1;
	return $out;
    }
}

sub summarize {
    my($options) = @_; ## reference to hash
    my %tallies = ();
    my $i;
    for($i = $$options{'dicermin'}; $i <= $$options{'dicermax'}; ++$i) {
	$tallies{'N'}{$i} = 0;
	$tallies{'Y'}{$i} = 0;
    }
    $tallies{'N'}{'N'} = 0;
    $tallies{'Y'}{'N'} = 0;

    my $res_file = "$$options{'outdir'}" . "\/" . "Results.txt";
    open(RES, "$res_file");
    my $Ngff3 = "$$options{'outdir'}" . "\/" . "ShortStack_N.gff3";
    open(N3, ">$Ngff3");
    my $Dgff3 = "$$options{'outdir'}" . "\/" . "ShortStack_D.gff3";
    open(D3, ">$Dgff3");
    my $Agff3 = "$$options{'outdir'}" . "\/" . "ShortStack_All.gff3";
    open(A3, ">$Agff3");



    print N3 "\#\#gff-version 3\n";
    print D3 "\#\#gff-version 3\n";
    print A3 "\#\#gff-version 3\n";

    my $chr;
    my $start;
    my $stop;

    my $simple_MIR;
    my $out_line;

    while (<RES>) {
	if($_ =~ /^\#/) {
	    next;
	}
	my @fields = split ("\t", $_);
	if($fields[0] =~ /^(\S+):(\d+)-(\d+)$/) {
	    $chr = $1;
	    $start = $2;
	    $stop = $3;
	    $simple_MIR = $fields[12];  ## from [13] before 3.7
	    $simple_MIR =~ s/\d+//g;
	    $out_line = "$chr\t";
	    $out_line .= "ShortStack\t";
	    $out_line .= "nc_RNA\t";
	    $out_line .= "$start\t";
	    $out_line .= "$stop\t";
	    $out_line .= "\.\t";  ## score
	    $out_line .= "$fields[7]\t";  ## from [8] before 3.7 strand
	    $out_line .= "\.\t"; ## ORF phase
	    $out_line .= "ID=$fields[1]\;";
	    $out_line .= "DicerCall=$fields[11]\;"; ## from [12] before 3.7
	    $out_line .= "MIRNA=$simple_MIR\;";
	    $out_line .= "\n";

	    print A3 "$out_line";

	    if($fields[11] =~ /[^\d]/) {  ## from [12] before 3.7
		++$tallies{$simple_MIR}{'N'};
		print N3 "$out_line";
	    } else {
		++$tallies{$simple_MIR}{$fields[11]}; ## from [12] before 3.7
		print D3 "$out_line";
	    }
	}
    }
    close RES;
    close N3;
    close D3;
    close A3;

    if(($$options{'locus'}) or ($$options{'locifile'})) {
	system "rm -f $Ngff3";
	system "rm -f $Dgff3";
	system "rm -f $Agff3";
    }


    # report to user
    my $time = `date`;
    chomp $time;
    log_it($$options{'logfile'}, "\n$time");
    log_it($$options{'logfile'}, "Tally of loci by predominant RNA size (DicerCall):\n");

    my $report;
    $report .= "DicerCall\tNotMIRNA\tMIRNA\n";
    $report .= "N or NA\t$tallies{'N'}{'N'}\t$tallies{'Y'}{'N'}\n";
    for($i = $$options{'dicermin'}; $i <= $$options{'dicermax'}; ++$i) {
	$report .= "$i\t$tallies{'N'}{$i}\t$tallies{'Y'}{$i}\n";

    }
    log_it($$options{'logfile'}, "$report");

    # summarize unplaced, if exists
    my $unp_file = "$$options{'outdir'}" . "\/Unplaced.txt";
    if(-r $unp_file) {
	# a hash for tracking
	my %unp_hash = ();
	# examine the file
	open(UNP, "$unp_file");
	while (<UNP>) {
	    if($_ =~ /^\#/) {
		next; ## header
	    }
	    my @unp_fields = split ("\t", $_);
	    my $unp_l = $unp_fields[1];
	    if($unp_l < $$options{'dicermin'}) {
		$unp_l = 'short';
	    } elsif ($unp_l > $$options{'dicermax'}) {
		$unp_l = 'long';
	    }
	    if($unp_fields[-1] =~ /^0$/) {
		# unplaced
		++$unp_hash{'N'}{$unp_l};
	    } elsif ($unp_fields[-1] =~ /\d/) {
		# some type of multi-mapper
		++$unp_hash{'M'}{$unp_l};
	    } elsif ($unp_fields[-1] =~ /^\?\?$/) {
		# no conflicting information for the sequence
		++$unp_hash{'??'}{$unp_l};
	    } else {
		# no info at all
		++$unp_hash{'?'}{$unp_l};
	    }
	}
	close UNP;
	my $unp_report = "Unplaced small RNAs\n";
	$unp_report .= "Size";
	my @types = sort keys %unp_hash;
	foreach my $t (@types) {
	    if($t eq 'N') {
		$unp_report .= "\tNoAlignments";
	    } elsif ($t eq 'M') {
		$unp_report .= "\tMultiMapped";
	    } elsif ($t eq '?') {
		$unp_report .= "\tUnknown";
	    } elsif ($t eq '??') {
		$unp_report .= "\tConflicting";
	    }
	}
	$unp_report .= "\n";

	$unp_report .= '<' . "$$options{'dicermin'}";
	foreach my $t (@types) {
	    if(exists($unp_hash{$t}{'short'})) {
		$unp_report .= "\t$unp_hash{$t}{'short'}";
	    } else {
		$unp_report .= "\t0";
	    }
	}
	$unp_report .= "\n";
	for(my $k = $$options{'dicermin'}; $k <= $$options{'dicermax'}; ++$k) {
	    $unp_report .= "$k";
	    foreach my $t (@types) {
		if(exists($unp_hash{$t}{$k})) {
		    $unp_report .= "\t$unp_hash{$t}{$k}";
		} else {
		    $unp_report .= "\t0";
		}
	    }
	    $unp_report .= "\n";
	}
	$unp_report .= '>' . "$$options{'dicermax'}";
	foreach my $t (@types) {
	    if(exists($unp_hash{$t}{'long'})) {
		$unp_report .= "\t$unp_hash{$t}{'long'}";
	    } else {
		$unp_report .= "\t0";
	    }
	}
	$unp_report .= "\n";
	log_it($$options{'logfile'}, "$unp_report");
    }
}

sub check_RNAfold_version {
    open(V, "RNAfold --version 2> /dev/null |");
    my $line = <V>;
    close V;
    if($line) {
	return '2';
    } else {
	return '1';
    }
}

sub get_total_primaries {
    my($options) = @_;  ## reference to hash
    if(exists($$options{'cramfile'})) {
	open(X, "samtools view -F 3840 -c $$options{'cramfile'} |");
    } else {
	open(X, "samtools view -F 3840 -c $$options{'bamfile'} |");
    }
    my $tally = <X>;
    close X;
    chomp $tally;
    $tally =~ s/\s//g;
    log_it($$options{'logfile'}, "\nTally of primary alignments (INCLUDES unmapped, but EXCLUDES secondary, duplicate,");
    log_it($$options{'logfile'}, "failed QC, and supplementary alignments): $tally");
    $$options{'total_primaries'} = $tally;

    # Now count the primaries that are placed:
    if(exists($$options{'cramfile'})) {
	open(X, "samtools view -F 3844 -c $$options{'cramfile'} |");
    } else {
	open(X, "samtools view -F 3844 -c $$options{'bamfile'} |");
    }
    $tally = <X>;
    close X;
    chomp $tally;
    $tally =~ s/\s//g;
    log_it($$options{'logfile'}, "\nTally of PLACED primary alignments (EXCLUDES unmapped, secondary, duplicate,");
    log_it($$options{'logfile'}, "failed QC, and supplementary alignments): $tally");
    $$options{'total_primaries_placed'} = $tally;
}

sub validate_sort_mem {
    my($options,$usage) = @_; ## references to hash, scalar
    # sort_mem is invalid unless aligning something
    if(exists($$options{'sort_mem'})) {
	unless(exists($$options{'readfile'})) {
	    die "\nOption --sort_mem is invalid unless you are aligning reads.\n\n$$usage\n";
	}
	# check format
	unless($$options{'sort_mem'} =~ /^\d+$|^\d+[KMG]$/) {
	    die "\nOption --sort_mem is not valid. It must be an integer (implies bytes as units) or end in K/M/G\n\n$$usage\n";
	}
    } elsif (exists($$options{'readfile'})) {
	# set to 768M by default
	$$options{'sort_mem'} = '768M';
    }
}

sub unplaced {
    my($options, $read_groups, $counts_fh, $threshold) = @_;
    # references to hash, hash, filehandle, scalar
    my %entries  = ();

    if(exists($$options{'bamfile'})) {
	open(SAM, "samtools view -f 4 $$options{'bamfile'} |");
    } elsif (exists($$options{'bamfile'})) {
	open(SAM, "samtools view -f 4 $$options{'cramfile'} |");
    } else {
	log_it($$options{'logfile'}, "\nERROR could not open bam or cram file for unplaced searching. Skipping\n");
	return 0;
    }
    my $seq;
    my $rg;
    while (<SAM>) {
	chomp;
	my @sf = split ("\t", $_);
	# get seq
	if($sf[1] & 16) {
	    $seq = reverse uc $sf[9];
	} else {
	    $seq = uc $sf[9];
	}
	$seq =~ s/T/U/g;
	my $n_hits;
	if($_ =~ /\tXY:Z:(\S)/) {
	    my $xyz = $1;
	    if($xyz eq 'M') {
		if($_ =~ /\tXM:i:(\d+)/) {
		    $n_hits = '>' . $1;
		} else {
		    $n_hits = '?';
		}
	    } else {
		if($_ =~ /\tXX:i:(\d+)/) {
		    $n_hits = $1;
		} else {
		    $n_hits = '?';
		}
	    }
	} else {
	    $n_hits = '?';
	}
	if($_ =~ /RG:Z:(\S+)/) {
	    if(exists($$read_groups{$1})) {
		$rg = $1;
	    }
	}
	if(exists($entries{$seq})) {
	    # n_hits must match up or convert entry to '??'
	    if($entries{$seq}{'n_hits'} ne $n_hits) {
		$entries{$seq}{'n_hits'} = '??';
	    }
	    ++$entries{$seq}{'main'};
	    if($rg) {
		++$entries{$seq}{$rg};
	    }
	} else {
	    $entries{$seq}{'main'} = 1;
	    if($rg) {
		$entries{$seq}{$rg} = 1;
	    }
	    $entries{$seq}{'n_hits'} = $n_hits;
	}
    }
    close SAM;

    # winnow
    while (($seq) = each %entries) {
	unless($entries{$seq}{'main'} >= $$threshold) {
	    delete $entries{$seq};
	}
    }

    # output to Unplaced.txt and Counts.txt
    my @rg_sorted = sort {$$read_groups{$a} <=> $$read_groups{$b}} keys %$read_groups;
    my $unplaced_file = "$$options{'outdir'}" . "\/Unplaced.txt";
    open(UNPLACED, ">$unplaced_file");
    print UNPLACED "\#RNA\tLength\tReads\tRPM\tN_hits\n";
    my @rnas = keys %entries;
    my @sorted = get_sorted_rnas(@rnas);
    my $rpm;
    foreach $seq (@sorted) {
	print UNPLACED "$seq\t";
	my $l = length $seq;
	print UNPLACED "$l\t";
	print UNPLACED "$entries{$seq}{'main'}\t";
	$rpm = sprintf("%.3f", 1E6 * ($entries{$seq}{'main'} / $$options{'total_primaries'}));
	print UNPLACED "$rpm\t";
	print UNPLACED "$entries{$seq}{'n_hits'}\n";

	print $counts_fh "$seq\tNA\t$entries{$seq}{'main'}\t";
	foreach $rg (@rg_sorted) {
	    if($rg eq 'main') {
		next;
	    }
	    print $counts_fh "\t";
	    if(exists($entries{$seq}{$rg})) {
		print $counts_fh "$entries{$seq}{$rg}";
	    } else {
		print $counts_fh "0";
	    }
	}
	print $counts_fh "\n";
    }
    close UNPLACED;
}

sub get_sorted_rnas {
    my(@input) = @_;

    my @sort1 = sort {length $a <=> length $b} @input;
    # now they should be sorted in ascending order by sRNA length

    # within each length, should be sorted by sequence
    my $last_length = -1;
    my @temp = ();
    my @out = ();
    my $this_l;

    foreach my $rna (@sort1) {
	$this_l = length $rna;
	if(($this_l != $last_length) and (@temp)) {
	    my @temp2 = sort @temp;
	    foreach my $x (@temp2) {
		push(@out, $x);
	    }
	    @temp = ();
	}
	push(@temp, $rna);
	$last_length = $this_l;
    }
    my @temp2 = sort @temp;
    foreach my $x (@temp2) {
	push(@out, $x);
    }
    return @out;
}

sub convert_coordinates {
    my($options,$original) = @_; # refs to hash, scalar
    my $o_chr;
    my $o_start;
    my $o_stop;
    my $s_range;
    my $s_chr;
    my $s_range_start;
    my $s_range_stop;
    my $s_start;
    my $s_stop;
    my $out;
    if($$original =~ /^(\S+):(\d+)-(\d+)$/) {
	$o_chr = $1;
	$o_start = $2;
	$o_stop = $3;
	    if(exists($$options{'stitchguide'}{$o_chr})) {
		$s_range = $$options{'stitchguide'}{$o_chr};
		if($s_range =~ /^(\S+):(\d+)-(\d+)$/) {
		    $s_chr = $1;
		    $s_range_start = $2;
		    $s_range_stop = $3;
		    $s_start = $o_start + $s_range_start - 1;
		    $s_stop = $o_stop + $s_range_start - 1;
		    $out = $s_chr . ':' . $s_start . '-' . $s_stop;
		    return $out;
		} else {
		    return 0;
		}
	} else {
	    return 0;
	}
    } else {
	return 0;
    }
}

sub is_large {
    my($options) = @_;
    # if more than 3,500,000,000 nts in genome per .fai file, it's large.
    unless(-r $$options{'fai_file'}) {
	log_it($$options{'logfile'}, "\nFATAL: Failed to read fai file $$options{'fai_file'} ABORTING\n");
	exit;
    }
    open(FAI, "$$options{'fai_file'}");
    my $n = 0;
    my @fields = ();
    while (<FAI>) {
	chomp;
	@fields = split ("\t", $_);
	$n += $fields[1];
    }
    close FAI;
    if($n > 3500000000) {
	return 1;
    } else {
	return 0;
    }
}


__END__

=head1 LICENSE

ShortStack

Copyright (C) 2012-2018 Michael J. Axtell

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

=head1 SYNOPSIS

Alignment of small RNA-seq data and annotation of small RNA-producing genes

=head1 CITATIONS

If you use ShortStack in your work, please cite one of the following:

=head2 VERSIONS 3.x and higher

Johnson NR, Yeoh JM, Coruh C, Axtell MJ. (2016). G3 6:2103-2111. doi:10.1534/g3.116.030452

=head2 OLDER VERSIONS

Axtell MJ. (2013) ShortStack: Comprehensive annotation and quantification of small RNA genes.  RNA 19:740-751. doi:10.1261/rna.035279.112

Shahid S., Axtell MJ. (2013) Identification and annotation of small RNA genes using ShortStack. Methods doi:10.1016/j.ymeth.2013.10.004

=head1 INSTALL

=head2 Dependencies

All dependencies must be executable and findable in the user's PATH

perl (version 5.x) : Generally installed in linux and mac machines by default. Expected to be installed at /usr/bin/perl

samtools (version 1.x or higher) : Free from http://www.htslib.org/

bowtie (if aligning) : Free from http://bowtie-bio.sourceforge.net/index.shtml  .. note: requires bowtie ... NOT bowtie2 !

bowtie-build (if aligning and .ebwt indices not found) : Free from http://bowtie-bio.sourceforge.net/index.shtml

gzip (if aligning) : Generally installed in linux and mac machines by default.

RNAfold (unless running with --nohp option to disable MIRNA search) : Part of the Vienna RNA package, Free from http://www.tbi.univie.ac.at/RNA/

=head3 Test environment

This release of ShortStack (3.8.4) tested on Mac OSX (10.10.5), perl 5.18.2, samtools 1.3.1, bowtie 1.2.0, RNAfold 2.3.2. It is known that samtools 1.x and higher is critical (no old 0.x samtools allowed).

=head2 Install

There is no real installation of ShortStack. Make sure it is executable. For convenience, can be added to your PATH. It expects your perl installation to be at /usr/bin/perl.

=head1 USAGE

Usage: ShortStack [options] {--readfile <r> | {--bamfile <b> | --cramfile <c>}} --genomefile <g>

<r> : readfile must be in fasta (.fasta or .fa), colorspace-fasta (.csfasta),
      or fastq (.fastq or .fq) format, or their gzip-compressed versions
      (.fasta.gz, .fa.gz, .csfasta.gz, .fastq.gz, or .fq.gz)
      Can also be a list (seperated by spaces) of several read files.

<b> : BAM formatted alignment file (.bam).

<c> : CRAM formatted alignment file (.cram).

<g> : FASTA formatted (.fa or .fasta) genome file.

=head1 TEST

Test data and brief instructions are available at http://axtelldata.bio.psu.edu/data/ShortStack_TestData/

=head1 OPTIONS

Note that we have done our best to set default settings for all options that are best for most users.

=head2 General Options:

--help : print a help message listing all options and quit

--version : print version and quit

--genomefile [string] : path to reference genome in .fasta or .fa format. Required for any run.

--outdir [string] : name of output directory to be created for results. Defaults to 'ShortStack_[time]',
  where [time] is the current UNIX time according to the system. If the directory already exists, ShortStack
  exits with an error message.

=head2 Alignment Options:

--readfile [string] : path to readfile(s) to be aligned. valid formats: .fasta, .fa, .fasta.gz,
  .fa.gz, .fastq, .fq, .fastq.gz, .fq.gz, .csfasta, .csfasta.gz. Multiple files, can be specified as
  separate arguments to --readfile ... e.g. --readfile file1.fastq file2.fastq file3.fastq
  Mutually exclusive with --bamfile or --cramfile.

--adapter [string] : sequence of 3' adapter to trim off during read-pre processing. Must be at least
  8 bases, with only ATCG characters. If not specified, reads are assumed to be already trimmed.

--bowtie_cores [integer] : Argument to be passed to bowtie's -p option, specifying number of processor
  cores to request during alignment. Defaults to 1. Must be an integer of 1 or more.

--sort_mem [string] : Argument to be passed to samtools sort -m option, which sets the maximum memory
  usage during bam file sorting. If not set, samtools sort defaults it to 768M. Higher settings will
  reduce the overall time spent in alignment phase, at cost of more memory usage. Use K/M/G suffixes to
  specify kilobytes, megabytes, and gigabytes, respectively. Extremely large alignment jobs will
  crash (due to crash of samtools sort operation) if --sort_mem is not set high enough. However, alignment
  jobs will also crash if sort_mem is set too high, and all physical memory on your machine is exahusted.

--mismatches [integer] : Argument to be passed to bowtie's -v option, specifying number of mismatches
  to be tolerated in a valid alignment. Must be either 0, 1, or 2. In cases of multiple hits, only hits
  with lowest number of mismatches kept. Default: 1.

--cquals [string] : path(s) to color-space quality value file(s). Used only in conjunction with .csfasta
  or .csfasta.gz formatted files in --readfile. Compressed format for cquals is NOT allowed. Like --readfile,
  cquals can take multiple arguments for multiple files, e.g. --cquals file1.qual file2.qual file3.qual

--cram : When aligning, convert final alignment to cram format instead of the default bam format.

--mmap [string] : Protocol for handling multi-mapped reads. Valid entries are n (none), r (random), u (unique-
  seeded guide), or f (fractional-seeded guide). default: u

--bowtie_m [string] : Setting to be passed to the -m option of bowtie. Over-ridden and set to 1 if option
  mmap is set to n. This sets the maximum number of multi-mappings allowed. Valid settings are integers >= 1 OR set 'all'
  to disable suppression of highly multi-mapped reads. Default: 50

--ranmax [string] : Reads with more than this number of possible alignment positions where the
  choice can't be guided by unequal  will be reported as unmapped. Irrelevant if option mmap is set
  to n or r. Must be integer of 2 or greater or set to 'none' to disable. Default: 3.

--align_only : If this switch is present, the ShortStack run will terminate after the alignment phase
  with no analysis performed.

--show_secondaries : If this switch is present, the output alignment file will contain secondary alignments
  as well as primary alignments for multi-mapped reads. Secondary alignments have bit 256 set in the SAM FLAG field.
  This option can increase alignment file size, sometimes by a lot.

--keep_quals : As of version 3.5, by default ShortStack alignments no longer store the quality values, to save space. Use
  of this switch will cause quality values to be retained. Note that this increases file size.

=head2 Analysis Options:

--bamfile [string] : path to input .bam alignment file of small RNAs. Only lines with bits 4 and 256
  unset will be used. Mutually exclusive with --readfile or --cramfile.

--cramfile [string] : path to input .cram alignment file of small RNAs. Only lines with bits 4 and 256
  unset will be used. Mutually exclusive with --readfile or --bamfile.

--dicermin [integer] : Minimum size of a Dicer-processed small RNA. Must be an integer of at least 15
  and <= dicermax. Default: 20.

--dicermax [integer] : Maximum size of a Dicer-processed small RNA. Must be an integer of at least 15
  and >= dicermin. Deafult: 24.

--foldsize [integer] : Size of genomic RNA segments for folding during MIRNA search. Any loci larger
  than this size will not be analyzed with respect for MIRNA features. Must be an integer of at
  least 200 and no larger than 1,000. Default: 300. Note that increasing this setting may drastically
  increase runtimes.

--locifile [string] : Path to a tab-delimited plain-text file listing intervals to analyze. Lines
  starting with # are ignored. First column is coordinate in format Chr:start-stop, second column
  is names (optional), and any other columns are ignored. Mutually exclusive with option --locus.

--locus [string] : Analyze the specified interval(s). Interval(s) is specified in format Chr:start-stop.
  Multiple intervals can be specified in a comma-separated list. Mutually exclusive with option
  --locifile.

--nohp : Disable MIRNA search.

--pad [integer] : Initially found clusters of small RNAs will be merged if the distance between them is
  less than or equal to the value of pad. Must be an integer between 0 and 50000. Default: 75.

--mincov [string] : Clusters of small RNAs must have at least this many alignments. Supply an
  integer between 1 and 50000. Can also be a normalized value in reads per million (rpm) OR reads per million mapped (rpmm). When specifying mincov in
  rpm or rpmm, the mincov value must be a floating point number > 0 and < 500,000 followed
  by the string 'rpm' or 'rpmm'. Examples: '5' --> threshold is 5 raw reads. '3.2rpm' --> threshold is
  3.2 reads per million mapped. '2.8rpmm' --> threshold is 2.8 reads per million mapped. Deafult: 0.5rpm.

--strand_cutoff [float] : Cutoff for calling the strandedness of a locus. Must be a floating point number
  between 0.5 and 1 (inclusive). DEFAULT: 0.8. At default of 0.8, a locus must have 80% of more of its
  reads on the top strand to be called a + strand locus, or 20% or less on the top strand to be a -
  strand locus. All others receive no strand call (e.g. '.'). Only stranded loci are analyzed for
  MIRNAs, while only unstranded loci are analyzed with respect to phasing. Most users probably want
  to use the default setting of 0.8.

--total_primaries [integer] : Tell ShortStack the total number of primary alignments in the bam file. Specifying
  this value here speeds the analysis, since ShortStack does not need to count the reads directly from the bam file.
  Can only be specified in conjunction with --bamfile. This count should include all primary alignment INCLUDING unplaced ones.

=head1 SYSTEM RECOMMENDATIONS

ShortStack was developed on Apple Mac OSX devices running 10.9 or 10.10. It has also been tested on
Linux (CentOS and Ubuntu).

At least 4G memory is suggested. Alignment and building bowtie indices tend to be the most
memory-intensive portions for a given run, and memory usage seems to scale with genome
size, but not as much with the number of small RNAs.

Alignments benefit from multiple processing cores, via the --bowtie_cores option. All other
portions are single-threaded.

Alignment speed may also be increased using the --sort_mem option to increase the memory used
for bam file sorting. Setting a higher --sort_mem will be REQUIRED for very large alignment
runs to avoid samtools sort crashes due to too many open files.

At least 50G of hard disk space is recommended to be available, due to the sometimes large
size of the temporary alignment files and the final alignment file. Extreme settings for options
--bowtie_m and --ran_max may cause creation of extremely huge files.

The total time of analysis depends on several factors, including most prominently genome size,
number of reads analyzed, whether or not bowtie indices need to be created, whether or not
MIRNAs are being analyzed, and of course your equipment.
Excluding building bowtie indices, we generally have observed run times for alignment + analysis runs
to take between 20 minutes and 10 hours using default ShortStack settings.

=head1 ALIGNMENT METHODS

If ShortStack is given the --readfile option, alignments of the reads will be performed. Specifying
--readfile is mutually exclusive with both --bamfile or --cramfile

=head2 Details of alignment methods and performance testing

For full details on ShortStack's alignment methods and the results of performance testing, see
Johnson et al. (2016) G3 6:2103-2111. doi:10.1534/g3.116.030452.


=head2 Genome pre-processing

=head3 Genome file format and naming

All runs require a reference genome in FASTA format, specified with the --genomefile option. The file must
end with a valid suffix .. either .fa or .fasta.

Within the genome, if the name of a chromosome has whitespace characters, the name will be trimmed at the first whitespace character.

=head3 Genome stitching

If the reference genome has > 50 chromosomes/scaffolds/contigs, and the genome N50 length is < 1Mb, and MIRNAs are
to be analyzed (e.g., --nohp was NOT specified), then ShortStack will 'stitch' the small chromosomes together to make
fewer but larger chromosomes. This can drastically improve performance during MIRNA searching for highly fragmented
genome assemblies. As of ShortStack 3.8, stitching has no effect on the results (e.g. results are reported relative
to the original genome, not the stitched one).

=head3 Genome indexing

If not detected, an index of the genome will be created using samtools faidx.

=head3 bowtie indices

If not detected, bowtie-build, using all default settings, will be invoked to create the required  six .ebwt
indices of the genome. This can be time-consuming, and memory intensive.

=head2 Reads pre-processing

=head3 Reads file formats

Small RNA reads to be aligned must be in fasta, fastq, or csfasta formats, or their gzip-compressed versions.
File names must end with .fa, .fasta, .fastq, .fq, .csfasta, .fa.gz, .fasta.gz, .fastq.gz, .fq,gz, or
.csfasta.gz.

Multiple readfiles can be specified with option --readfile by separating the file names/paths with commas. Colorspace
reads cannot be mixed with base-space reads; otherwise, mixed file formats are ok.

If you wish to also include quality values from SOLiD data, the _QV.qual file(s) can be passed in through the
--cquals option. Color-space quality values are NOT accepted in .gz compressed format.

=head3 No paired-end support

There is no support for paired-end reads in ShortStack. Small RNA data are assumed to be single-ended, and represent the
5'-->3' cDNA sequences of cloned RNAs.

=head3 No condensation

Input reads are expected to be de-condensed. That is, if a small RNA was sequenced 10,000 times in a run, there should be
10,000 entries, each with a different header name, in the input readfile. In other words, ShortStack is designed
to take reads right off the sequencer without any other pre-processing (except adapter trimming .. see below).

=head3 Unique read names required

The small RNA reads must all have unique names within a given file. If this requirement is not met, alignments will be
completely unreliable due to errors in interpreting and handling of multi-mapped reads.

=head3 Adapter trimming

ShortStack has a primitive 3'-adapter capability. Specify an adapter of at least 8nts in length with option --adapter.
If nothing is given to --adapter, ShortStack assumes your reads are already trimmed. Trimming simply looks for the
right-most exact match to the given apdater sequence, and when found, chops it off. If a read is smaller than 15nts
after trimming, it is discarded. For more sophisticated adapter trimming, consider cutadapt or trimmomatic

If quality values are present, they are trimmed as well.

=head2 Alignment overview

ShortStack uses bowtie to align reads. It first aligns, and processes the output on the fly to note how many equally good
alignment positions were found for each read. It then uses this information in a second phase to 'decide' on the most likely
'correct' location for multi-mapped reads. The final output is a single .bam or .cram formatted alignment file. If multiple
readfiles were input, the final bam or cram file notes the origin of each read with the RG tag (see sam format specification).

=head3 mismatches

By default, ShortStack allows up to 1 mismatch for a valid alignment. This helps with sequencing errors and SNPs. If a read
has some alignments with 0 mismatches, and some with 1, only those with 0 mismatches are kept. The option --mismatches
controls this threshold, and can be set to 0, 1, or 2.

*** WARNING : If the genome is large (.ebwtl bowtie indices are made, instead of .ebwt), there is a serious bowtie bug
that has yet to be resolved involving the --best option. http://sourceforge.net/p/bowtie-bio/bugs/343/ .
To get around this, when aligning to a 'large' reference, ShortStack forces the number of allowed mismatches to be 0.

=head3 Control of multi-mappers with --bowtie_m

In general, we find it's not worth the time or effort to deal with 'extreme' multimapping reads. The --bowtie_m
setting determines the threshold of 'extreme' multi-mappers. Reads that have more than --bowtie_m alignments
are simply marked as unmapped. The default setting is 50. Valid settings are >=1 or set 'all' to disable
any suppression of extreme multi-mappers (not suggested).

=head3 Optimal placements of multi-mapped reads

For multi-mapped reads that have between 2 and --bowtie_m number of equally good alignments,
ShortStack has several methods to decide on the true origin of the read. The choice of method is
specified with the option --mmap. The methods are:

u: Placement guided by uniquely mapping reads. During the alignment, the count of uniquely mapped
reads is kept in 50nt bins across the reference genome. The bin location is determined by the
left-most coordinate of the uniquely mapped read. After the first phase of alignment for
all reads (in all files) has completed, this genome-wide map of uniquely-mapped read counts
is used to guide the decisions of the most likely locations of multi-mapped reads. Specifically,
for a given multi-mapped read, the local count of uniquely mapped reads at each possible location
is computed. The local count is that of the specific 50nt bin the alignment lies in (again,
by left-most positon) plus the counts of the 2 bins upstream and 2 bins downstream. All of the local
counts are converted to fractions of the sum of all total counts. These fractions are then
used as the probabilities of placement for the multi-mapped read.  For instance, suppose a multi-mapped
read had three possible positions. The read counts of uniquely mapped reads were 30, 65, and 5.
This would mean that read has a 30%, 65%, and 5% chance, respectively, of being assigned to each
bin. The actual choice is probabilistic, given the computed weightings, for each read.

f: Placement guided by all mapped reads. Like u, except that multi-mapped reads also
contribute to the guidance densities. All reads contribute 1/(n of alignment positions) to
each 50nt bin that the occur in.

r: Placement is simply random. This is faster than u and f, but performs much more poorly at
properly placing multi-mapped reads. Achieves high sensitivity, but very low precision.

n: Multi-mapped reads are all ignored and marked as unmapped. Very fast, but ignores large
quantities of data. Achieves high precision, but very low sensitivity.

The default setting for --mmap is u

=head3 ranmax

When running mmap method u or f, there are some cases where no guidance can be given, and
so the choice on where to put a multi-mapped read is still random. In those cases, the option
ranmax will suppress any alignment where the choice is 'too' random. By default, --ranmax is
set at 3, so that if a read can't be placed confidently, no placement is done if there
are more than 3 choices.

=head2 Alignment output format

Final alignments are sorted bam or cram formatted alignments. bam is the default, while cram is created if the option --cram is set.
The alignment file conforms to all SAM/BAM/CRAM format specifications, and has the following features:

Headers contain @RG lines to describe each read-group (input readfile).

For multi-mapped read alignments that were NOT chosen as the most likely alignment, bit 256 (secondary alignment) is set in the FLAG.
For such lines, the SEQ and QUAL values are not stored, to save space. The SEQ and QUAL for
multi-mapped alignments are kept only in the primary (chosen) alignment for the read.

XX:i tags: Added by ShortStack to each line, this indicates the total number of valid alignments
found for the read.

XY:Z tags: Added by ShortStack to each line, this indicates how the reported alignment was selected:
U: Uniquely mapped, P: Multi-mapped and placed based on probabilities calculated by mmap method u or f,
R: Multi-mapped and randomly placed, M: Multi-mapped but marked as unmapped becuase the number of
alignment positions exceeded --bowtie_m, O: Multi-mapped but marked as unmapped because no guidance
possible and choices exceeded setting --ranmax, N: Unmapped because 0 valid alignments found in genome.

XZ:f tags: Added by ShortStack to each line, this indicates the calculated probability of placement
for the read.

=head1 BAM AND CRAM FILE REQUIREMENTS

Existing alignments can be provided to ShortStack using the --bamfile or --cramfile options
(for bam formatted and cram formatted alignments, respectively). --bamfile and --cramfile are
mutually exclusive with each other, and with --readfile.

Any properly formatted bam or cram file should work with ShortStack, subject to the requirements
below. However, for best performance, it is recommended to use ShortStack for alignments as well.

Requirements for input bam or cram files:

1. Header must be present, and contain @SQ lines.

2. File most be sorted.

3. Read groups will not be recognized unless they are properly noted in the header.

4. Paired-end, spliced, clipped, padded, or gapped alignments will be ignored, with a warning to
the user. Reads marked as secondary alignments (bit 256 set in the FLAG) will not be used.

=head1 DE-NOVO CLUSTER FINDING

Unless options --locus or --locifile are used (see below), ShortStack will de-novo identify
clusters of small RNA accumulation genome-wide. Cluster definition is simple:
First, all regions containing at least one primary alignment are found where the maximum
distance between the ends of the alignments is <= option --pad (default: 75). Second,
if the number of alignments in the cluster is >= option --mincov (default: 0.5rpm), the cluster
is kept. The mincov threshold can also be specified in terms of reads per million
by using a value such as 3.2rpm (which specifies the threshold to be 3.2 reads per million).
Using a rpm threshold allows the sensitivity of cluster discovery to be normalized between
libraries of different sizes. Alternatively, reads per million mapped (rpmm) can be specified:
A --mincov of 1.2rpmm indicates 1.2 reads per million mapped is the threshold. rpm is a fraction
of total library size, while rpmm is a fraction of only the aligned & placed fraction of the library.

=head1 UNPLACED SMALL RNAS

As of version 3.6 and higher, de-novo identification of small RNA clusters also will include
reporting of unplaced small RNAs ... small RNAs that were not placed on the reference genome.
Only small RNAs with an abundance higher than the limit set by option --mincov are reported.
These small RNAs typically inlcude RNAs that could not be aligned anywhere on the reference, as
well as multi-mapped RNAs where ShortStack did not choose a alignment position for (see alignment
methods).

=head1 USER-SPECIFIED CLUSTERS

Users can supply specific loci to analyze in two ways. For just one or a few loci, the option
--locus can be used. The argument should be a coordinate in the format Chr:Start-Stop. Multiple
loci can be specified in option --locus by using commas to delimit them.

For larger lists of user-defined loci, and external file can be used instead, specified with option
--locifile. The file is a plain-text , tab-delimited format. The first column should list the coordinates
in Chr:Start-Stop format. An optional second column can contain names of the loci. Any other columns
will be ignored. Also, lines starting with # will be ignored.

Options --locus and --locifile are mutually exclusive. Also, if either is used, no de-
novo cluster finding occurs.

=head1 ANALYSIS METHODS

Regardless of whether the small RNA clusters were de-novo discovered or user-defined, the analysis
methods of each cluster are the same. The major methods are described below:

=head2 Read-group-specific counts

Quantification occurs separately for each read-group in the alignment. The results are
in the 'Counts.txt' file, which has the observed number of reads, the mean number of reads
for the ten re-samplings, and the standard deviations. When there are multiple read-groups,
this is helpful to gather the raw data for differential expression analysis.

There is always a read-group called 'main', which is all read-groups combined.

=head2 Strandedness of loci

Loci where >= 80% of the primary alignments are on the top genomic strand are noted with a
strand of +. Loci where <=20% of the primary alignment are on the top genomic strand are noted
with a strand of -. All other loci are given a strand of .

=head2 Major RNA

For each locus analyzed, the single most abundant RNA is noted and the sequence reported. In cases
where there is a tie, the reported major RNA is chosen arbitrarily from among the tied RNAs.

=head2 Complexity

Complexity is a metric that varies from >0 to 1. It is calculated as (n distinct alignments) / (abundance of
alignments), thus lower values indicate loci dominated by just a few dominant RNAs, while higher
values indicate loci with more diverse sets of small RNAs.

=head2 DicerCall

The 'DicerCall' reflects the predominant RNA size observed in the locus. However, if < 80% of the
reads in a locus are NOT within the bounds described by the options --dicermin and --dicermax, then
the DicerCall is 'N' instead. DicerCalls of N usually reflect loci where the small RNAs are NOT
related to an RNAi process ... most often, breakdown products of abundant RNAs.

Note that the predominant RNA size need not be a majority .. for instance a locus with
40% 21 mers, 39% 22 mers, and 21% 23 mers would have a DicerCall of 21.

=head2 MIRNAs

ShortStack's MIRNA analysis is meant to eliminate false positives. It therefore probably allows
some degree of false negatives (e.g., loci that really are MIRNAs but are not annotated as
such).  MIRNA analysis in ShortStack version 3 is a step-wise process. If a locus fails a
certain step, it is removed from consideration and given a specific code indicate what step
it failed.  The codes are below in step-wise order. The Major RNA is always hypothesized to
be the mature miRNA in the locus.

Note that MIRNA analysis is limited to loci that are <= the length specified by option
--foldsize ... the default setting is 300 nts. Increasing this size may allow you to find
more MIRNAs, but will also slow down the runtime of the process.

MIRNA analysis codes:

N0: not analyzed due to run in --nohp mode.

N1: no reads at all aligned in locus

N2: DicerCall was invalid (< 80% of reads in the Dicer size range defined by --dicermin and --dicermax).

N3: Major RNA abundance was less than 2 reads.

N4: Major RNA length is not in the Dicer size range defined by --dicermin and --dicermax.

N5: Locus size is > than maximum allowed for RNA folding per option --foldsize (default is 300 nts).

N6: Locus is not stranded (>20% and <80% of reads aligned to top strand)

N7: RNA folding attempt failed at locus (if occurs, possible bug?)

N8: Strand of possible mature miRNA is opposite to that of the locus

N9: Retrieval of possible mature miRNA position failed (if occurs, possible bug?)

N10: General failure to compute miRNA-star position (if occurs, possible bug?)

N11: Possible mature miRNA had > 5 unpaired bases in predicted precursor secondary structure.

N12: Possible mature miRNA was not contained in a single predicted hairpin

N13: Possible miRNA/miRNA* duplex had >2 bulges and/or >3 bulged nts

N14: Imprecise processing: Reads for possible miRNA, miRNA-star, and their 3p variants added up to less than 50% of the total reads at the locus.

N15: Maybe. Passed all tests EXCEPT that the miRNA-star was not sequenced. INSUFFICIENT evidence to support a de novo annotation of a new miRNA family.

Y: Yes. Passed all tests INCLUDING sequencing of the exact miRNA-star. Can support a de novo annotation of a new miRNA family.

For loci where MIRNA analysis returns a Y (yes) result, a plain-text summary of the locus and its
secondary structure is found in the MIRNAs directory.

Users should be aware that sometimes ShortStack will annotate known miRNA-stars as miRNAs, if the
abundance of the miRNA-star in the analyzed library is higher.

MIRNA analysis can be disabled with the --nohp option. This may save significant analysis time.

As of ShortStack version 3.x, MIRNA analysis is geared toward plant MIRNAs. It probably is just
fine for animal MIRNAs too, but has not been tested on them.

=head2 Phasing

Phasing here refers to a signature of periodicity of small RNA abundance that reflects dsRNA
processing from a defined terminus. Phased siRNA clusters often are triggered by an upstream
small RNA-mediated clevage event which causes RNA-dependent RNA polymerase activity and subsequent
siRNA production from the terminus defined by the cleavage event.

For valid loci, ShortStack 3.7 and above uses a modified version of the  formula described by Guo et al. (2015) (doi: 10.1093/bioinformatics/btu628),
S = PR * PN * ln(1 + PArpm), where S is the phase score, PR is the phase ratio (see Axtell 2010 doi: 10.1007/978-1-60327-005-2_5),
PN is the number of distinct sequences that are phased, and PArpm is the abundance of the phased reads in units of reads per million.

ShortStack calculates the phase score in a 21 nt phase size for loci with a DicerCall of 21, or in a
24 nt phase size for loci with a DicerCall of 24,
and returns the score.  Higher phasing scores indicate
more phasing signature. Phase scores range from very near 0 (worst) up.

The modification of the Guo et al. formula, first implemented in ShortStack version 3.7, makes the PhaseScore numbers
comparable between different libraries. A score of ~30 or more indicates a well-phased locus.

Not all loci are subject to phasing analysis. Loci with no reads at all aligned, a DicerCall of anything except 21 or 24, a Locus Size of < 3 * DicerCall, and stranded loci (>= 80% of reads on top strand OR <= 20% of reads on top strand) are not analyzed. These are assigned a PhaseScore of -1.

=head1 OUTPUT FILES

All output files are in the directory created by ShortStack, whose name is specified by option --outdir
The exceptions are the .fai file (genome index file) created if it is not present and the six ebwt
bowtie index files that are created if not present ... these are all put in the
same location as the input genome file.

=head2 Log file

A log of the run messages is created and written to Log.txt. It is the same as the
messages printed to STDERR during the run.

=head2 ErrorLogs

For debugging. Most users won't need to look at this. It stores the verbose outputs of bowtie-build,
bowtie, samtools sort, and samtools merge commands that are not kep in the main Log. Sometimes these are
helpful in diagnosing bugs, particularly samtools sort and merge bugs due to memory issues.

=head2 Stitched genome file

If the input genome was 'stitched' (see above), the stitched genome file will be
put in the ShortStack outdir, along with its fai index temporarily during the run.
Both files will be deleted at the end of the run so you won't see them unless your
run was killed before completion for some reason.

=head2 Results file

The file Results.txt is a plain-text tab-delimited file that contains the core results of
the analysis. The columns are labeled in the first row, and are:

1. Locus: Coordinates of the locus in format Chr:Start-Stop

2. Name: Name of the locus

3. Length: Length of the locus (nts)

4. Reads: Total number of primary alignments in the locus

5. RPM: Total number of primary alignments normalized to reads per million. Note the the normalization factor includes all primary alignments .. both mapped and unmapped.

6. UniqueReads: Number of uniquely aligned primary alignments in locus.

7. FracTop: Fraction of primary alignments aligned to the top genomic strand

8. Strand: Strand call for the locus

9. MajorRNA: Most abundant RNA at locus. In cases of tie, MajorRNA is arbitrarily chosen from the tied entries.

10. MajorRNAReads: Number of primary alignments for the MajorRNA.

11. Complexity: A number >0 and <= 1 that reflects the complexity of small RNA production from the locus. Defined by (n_distinct_read_sequences) / (abundance of all reads). Lower numbers indicate loci that are more dominated by a single highly abundant RNA.

12. DicerCall: If >= 80% of the primary alignments were reads >= dicermin and <= dicermax, DicerCall is a number that indicates the predominant size of the RNA population from the locus. If the 80% threshold was not met, then DicerCall is N instead. Can also be NA if the locus had no aligned reads.

13. MIRNA: Results of MIRNA analysis. Codes starting with N indicate not a MIRNA, Y means yes. See above for full description of codes.

14. PhaseScore:  Phasing score for a phase size of 21 or 24nts according to a modified version of equation 3 of Guo et al (2015) doi: 10.1093/bioinformatics/btu628. If the locus had a DicerCall of 21, phase score is for a 21 nt phasing register. If the locus had a DicerCall of 24, the phase score is for a 24 nt phasing register. See above for full description of phasing analysis.

15. Short: Number of primary alignments that were shorter than --dicermin

16. Long: Number of primary alignments that were longer than --dicermax

17-end: Number of primary alignments of the indicated RNA size.

=head2 Unplaced file

The Unplaced.txt file is plain text, tab-delimited. It shows each unplaced small RNA whose abundance was >= the limit set
by --minocv. This file is only created in a de-novo run. RNAs are sorted first by length (ascending) and then by ASCII (ascending).
Columns show the sequence, its length, the total number of reads, the reads per million (RPM) and the number of equally valid genome alignments.

In some cases the number of genome alignments may not be able to be found. An entry of '?' indicates that the number of hits
is unknown. This will occur if the BAM file used was not created by ShortStack. An entry of '??' indicates that conflicting
information about the number of hits is stored in the bam file.

=head2 Counts file

The Counts.txt file is plain text, tab-delimited. For each locus, it shows the total raw read counts. Each
read-group is broken out seperately, and the sum of all read groups is also shown (termed 'main'). Data from
unplaced small RNAs, if present, are also included in Counts.txt

=head2 MIRNAs directory

This directory contains plain-text descriptions of each locus that was judged 'M' or 'Y' in MIRNA analysis. The files
show the sequence of the locus, the predicted RNA secondary structure in dot-bracket notation, and the locations of
the miRNA and miRNA-star. If the miRNA-star was not sequenced, its sequence is shown as 'X's instead of the real
sequence.

Below this top line, all other small RNAs aligned to the locus are shown. Those aligned to the opposite strand have
'<' as delimiters instead of '.'.

Lower-case nts in the displayed small RNA sequences indicate positions where the small RNA sequence differs from
the reference sequence. Note that the reference sequence, not the small RNA sequences, are used to compute
predicted secondary structures.

l: length of RNA, a: number of alignments.

=head2 GFF3 files

If the run was a de-novo analysis, three gff3 files are created to indicate the positions of the discovered loci.

ShortStack_N.gff3 has the loci with DicerCalls of 'N' (e.g., those that are unlikely RNAi-related).

ShortStack_D.gff3 has the loci with DicerCalls that were not 'N' (e.g., those that ARE likely RNAi-related).

ShortStack_All.gff3 has ALL loci (it is the merger of the other two gff3 files).

=head2 bam or cram alignment file

If aligment was performed, the final bam or cram formatted alignment will also be in the ShortStack outdir. The
ShortStack-specific tags of these files are described above (section Alignment output format).

=head1 FAQ

=head2 bowtie2 is newer than bowtie. Why do you still require bowtie but disallow bowtie2?

Answer: Three reasons. 1) unlike bowtie2, bowtie has support for colorspace data, and 2) According to the manuals for both programs, bowtie2 is optimized for longer (>50 nts) reads, while bowtie is optimized for shorter reads. 3) Time. Despite the above comments, we will explore this transition in future versions of ShortStack.

=head2 Why does ShortStack say that are known MIRNA loci are NOT MIRNAs?

Answer: MIRNA annotation by ShortStack is, by design, meant to strongly reduce, perhaps eliminate, false positives. Any locus given a MIRNA result of 'Y' by ShortStack has sufficiently strong evidence to support its annotation of a miRNA. However, reduction of false positives comes at a price .. there will be some false negatives .. true MIRNAs that are not reported as such by ShortStack. Users should consider a 'No' MIRNA result by ShortStack to mean that the evidence in that particular small RNA-seq run did not offer 100% proof that the locus was a MIRNA.

=head2 I ran the same analysis, with the same reads, and the same settings a second time, and received slightly different results. Is this a bug?

Answer: No. This is caused by the treatment of multi-mapped reads. Because the decisions on which of the possible alignment positions are probabilistic, some small number of the reads will be differ in their selected primary positions when alignments are repeated. This is normal, and typically the differences are minor.

=head2 I get different numbers of MIRNAs with ShortStack 3 relative to earlier versions. Why?

Answer: The MIRNA detection methods have changed significantly. You may find ShortStack 3 to be more strict (find fewer MIRNAs) relative to earlier versions. This is because false positives are really minimized with ShortStack 3, potentially at the expense of some false negatives.

=head2 What happened to the flagfile option from earlier versions of ShortStack?

Answer: It is gone. This was a rather crude way to assess overlaps between ShortStack-discovered clusters and loci of a user's interest. Use bedtools instead (using the gff3 output from ShortStack).

=head2 Are the read counts reported by ShortStack normalized in any way?

Answer: The column 'Reads' in the Results is just the raw reads. The column 'RPM' in the Results is the reads per million, calculated on the basis of all aligned + unaligned reads in the library.

=head2 ShortStack seems to be slow. Why? And how to make it go faster?

Answer: To make alignments go faster, use the --bowtie_cores and --sort_mem options to make full use of your system. Their default settings (1 core, and sort_mem of 768M) are quite low to ensure success on low-powered machines, but if you have more cores and memory available, raising these will speed alignments along quite a bit. Another way to make alignments go faster is to specifiy r or n for option --mmap. But there is a trade-off there .. r causes multi-mapped reads to be just placed randomly instead of more intelligently, while n causes all multi-mappers to be marked as unmapped. So, if you use --mmap of r or n, you will get a much faster alignment, but a much less sensitive and precise one.  There are also some tricks to increase the speed of analysis, but they all also involve some down-side. You can set option --nohp, which means that MIRNAs will not be tested for. This will increase the speed of analysis but of course you won't be able to annotate MIRNAs. You can also adjust the option --mincov to have a higher threshold. This will cause fewer loci to be discovered (only those with higher expression levels), so analysis time will be reduced. But of course the trade-off there is that you will not discover loci with lower expression levels. The current default of mincov 0.5rpm should be a good balance of sensitivity and speed for most applications.
