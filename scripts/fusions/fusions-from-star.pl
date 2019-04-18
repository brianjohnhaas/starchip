#! /usr/bin/perl
use warnings;
use strict;
use Cwd 'abs_path';
use Getopt::Long;
use File::Basename;
use FindBin;
use lib("$FindBin::Bin/../../perllib");
use Process_cmd;

set_debug_level(1);

## usage: fusions-from-star.pl  outputname Chimeric.out.junction  

##IMPORTANT NOTE!  this calls 'samtools' and 'bedtools' and 'mafft'  please have these installed and in your path under those aliases.  
	#It shouldn't crash without them, but you will get error messages rather than some of the outputs.
	#$ On MSSM/minerva you can just do: module load starchip

# to do:    
	# blat/blast output.  blat is REALLY slow, and because of mem loading, probably faster if run in batches.  
		# run all blat at once.
		# $ blat t=dna q=rna /path/to/database /path/to/query 
		# the other issue is that blat/blast don't lend themselves to computational filtering easily.  taking the top hit works ok though.   

if (scalar(@ARGV) != 3 ) { die "Wrong number of inputs. Usage: fusions-from-star.pl output_seed input_chimeric.out.junction params.txt \n Be sure you have samtools, bedtools, and mafft available.\n";}

##Read in User Parameters (taken from Perl Cookbook "8.16. Reading Configuration Files")
my %Configs = ();
my $configfile = $ARGV[2]; 
open CONFIG, "<$configfile" or die "Error, cannot read config file: $configfile";
while (<CONFIG>) {
    chomp;                  # no newline
    s/#.*//;                # no comments
    s/^\s+//;               # no leading white
    s/\s+$//;               # no trailing white
    next unless length;     # anything left?
    my ($var, $value) = split(/\s*=\s*/, $_, 2);
    $Configs{$var} = $value;
}

if (get_log_level() > 0) {
    use Data::Dumper;
    print "fusions-from-star.pl, config setting:\n";
    print Dumper(\%Configs);
}

#These shouldn't change unless the format of Chimeric.out.junction from star changes:
my $col_jxntype=6;
my $col_startposA=10;
my $col_startposB=12;
my $col_cigarA=11;
my $col_cigarB=13;
my $col_chrA=0;
my $col_chrB=3;
my $col_FusionposA=1;
my $col_FusionposB=4;
my $col_strandA=2;
my $col_strandB=5;
my $col_overlapL=7;
my $col_overlapR=8;
my $numbcolumns=14; #need this one in case you junciton.out file/input changes.  this should be a non-existant final column (ie Chimeric.junciton.out has 0-13 columns)
#should fix this to be more robust...

 
#set variables
my $linecount=0;
my $readlength =0;
my %fusions =();
my $script_dir=abs_path($0);
$script_dir =~ s/fusions-from-star.pl//;
my $consensusloc= $script_dir . 'consensus.sh';
my $annotateloc= $script_dir . 'coordinates2genes.sh';
my $blastscript = $script_dir . 'check-pseudogenes.sh'; 
my $smithwaterman = $script_dir . 'smith_waterman.pl';
my $data_dir = abs_path($0) ; 
$data_dir =~ s/\/scripts\/fusions\/fusions-from-star.pl//;

my $abpartsfile = $data_dir . "/" . $Configs{abparts} ;
my $troublemakers = $data_dir . "/" . $Configs{falsepositives} ;
my $familyfile = $data_dir . "/" . $Configs{familyfile} ;
my $cnvfile = $data_dir . "/" . $Configs{cnvs} ; 


if (get_log_level() > 0) {
    print "fusions-from-star.pl settings:\n"
        . "script_dir = $script_dir\n"
        . "consensusloc = $consensusloc\n"
        . "annotateloc = $annotateloc\n"
        . "blastscript = $blastscript\n"
        . "smithwaterman = $smithwaterman\n"
        . "datadir = $data_dir\n"
        . "abpartsfile = $abpartsfile\n"
        . "troublemakers = $troublemakers\n"
        . "familyfile = $familyfile\n"
        . "cnvfile = $cnvfile\n\n";
}


unless (-e $abpartsfile ) { #if the file isn't in starchip/
	$abpartsfile = $Configs{abparts} ; #check the absolute path
	unless (-e $abpartsfile ) {
		print "Warning: Can not find your Antibody Parts File: $Configs{abparts} or $data_dir/$Configs{abparts} \n";
	}
}
unless (-e $troublemakers ) { #if the file isn't in starchip/
	$troublemakers = $Configs{falsepositives} ; #check the absolute path
	unless (-e $troublemakers ) {
		print "Warning: Can not find your False Positives File: $Configs{falsepositives} $data_dir/$troublemakers\n";
	}
}
unless (-e $familyfile ) { #if the file isn't in starchip/
	$familyfile = $Configs{familyfile} ; #check the absolute path
	unless (-e $familyfile ) {
		print "Warning: Can not find your Gene Families File: $Configs{familyfile} or $data_dir/$familyfile\n";
	}
}
unless (-e $cnvfile ) { #if the file isn't in starchip/
	$cnvfile = $Configs{cnvs} ; #check the absolute path
	unless (-e $cnvfile ) {
		print "Warning: Can not find your Copy Number Variants File: $Configs{cnvs}\n or $data_dir/$cnvfile \n";
	}
}

#file management
my $outbase = $ARGV[0];
#$outbase =~ 's/\'//' ; 
my $outsumm = $outbase . ".summary";
my $outsummtemp = $outsumm . ".temp";
my $outannotemp = $outsummtemp . ".annotated" ;
my $outanno = $outsumm . ".annotated";
my $junction = $ARGV[1];
my $sam = $junction;
$sam =~ s/junction$/sam/ ;
my $starbase = $junction ;
$starbase =~ s/Chimeric.out.junction//;    


#index the antibody regions for this genome:
print STDERR "-processing abpartsfile: $abpartsfile\n";
open ABS, "<$abpartsfile" or die "Error, cannot read $abpartsfile";
my @AbParts;
my $abindex=0; 
while (my $x = <ABS>) {
	$x =~ s/^chr// ; #we strip out chr beginings to make everything line up ok. 
        my @line = split(/\s+/, $x); #AbParts lines are formatted: chrm pos1 pos2
        $AbParts[$abindex][0]{$line[0]} = $line[1]; ##data format: $AbParts[index][0=lower/1=upper position]{chrom}
        $AbParts[$abindex][1]{$line[0]} = $line[2]; ##data format: $AbParts[index][0=lower/1=upper position]{chrom}
        $abindex++;
}

### AUTOMATIC THRESHOLDING 
#determine the number of uniquely mapped reads
my $logfinalout = $starbase . "Log.final.out" ;
open LOGFINAL, "<$logfinalout" or die "cannot open $logfinalout\nHave you moved Chimeric.out.junction out of the original STAR output directory?  STARChip uses several files automatically generated by STAR\n";
my @loglines = <LOGFINAL> ;
my @uniqreadcount = grep(/Uniquely mapped reads number/, @loglines);
my ($trashtext, $readcount) = split(/\|/, $uniqreadcount[0]);
$readcount =~ s/^\s+|\s+$//g; #strip whitespace


if ( lc $Configs{"splitReads"} eq "auto" || lc $Configs{"splitReads"} eq "highsensitivity" || lc $Configs{"splitReads"} eq "highprecision" ) {
	print "Performing Automatic Threshold Targeting For Split Reads\n";
	#my $cutoff = $readcount / 3000000 ; 
	my $cutoff = $readcount / 3571429 ; # 0.28 reads per million mapped 
	if ( lc $Configs{"splitReads"} eq "highsensitivity" ) {
                $cutoff = $readcount / 20000000 ; ## 0.05 reads per million mapped
        }
        if ( lc $Configs{"splitReads"} eq "highprecision" ) {
                $cutoff = $readcount / 847458 ;  ## 1.18 reads per million mapped
        }
	$cutoff = sprintf "%.0f", $cutoff;
	if ($cutoff < 0 ) { die "Error Calculating read based cutoffs. STAR output Log.final.out reports $readcount reads\n" }
	if ($cutoff == 0 ) { $cutoff++; }
	print "Uniquely Mapped Reads:$readcount\nSelected Cutoff: $cutoff\n";
	$Configs{splitReads} = $cutoff;  
}  
##do the same for spanning (paired) reads
if ( lc $Configs{"spancutoff"} eq "auto" || lc $Configs{"spancutoff"} eq "highsensitivity" || lc $Configs{"spancutoff"} eq "highprecision" ) {EXITER:{
        print "Performing Automatic Threshold Targeting For Spanning Reads\n";
	if ( lc $Configs{"pairedend"} ne "true" ) { $Configs{spancutoff} =0; print "Paired-End config not set to TRUE, setting limits for single-end data\n" ; last EXITER;} 
	my $cutoff = $readcount / 3000000 ; # 0.33 reads per million mapped
	#this choice of reads/7.5M is somewhate arbitrary.  The ratio of split/span reads should be a function of:
	#read length and fragment/insert length.
	#High Sensitivity Mode
	if ( lc $Configs{"spancutoff"} eq "highsensitivity" ) {
		$cutoff = $readcount / 20000000 ; ## 0.05 reads per million mapped
	}
	if ( lc $Configs{"spancutoff"} eq "highprecision" ) {
		$cutoff = $readcount / 847458 ;  ## 1.18 reads per million mapped
	}
        $cutoff = sprintf "%.0f", $cutoff;
        if ($cutoff < 0	) { die	"Error Calculating read based cutoffs. STAR output Log.final.out reports $readcount reads\n" }
        if ($cutoff == 0 ) { $cutoff++;	}
        print "Uniquely Mapped Reads:$readcount\nSelected Cutoff: $cutoff\n";
        $Configs{spancutoff} = $cutoff;	 
} }
print "\nUsing the following variables:\nPaired-End: $Configs{pairedend}\nSplit Reads Cutoff: $Configs{splitReads}\nUnique Support Values Min: $Configs{uniqueReads}\nSpanning Reads Cutoff: $Configs{spancutoff}\nLocation Wiggle Room (spanning reads): $Configs{wiggle} bp\nLocation Wiggle Room (split reads) : $Configs{overlapLimit} bp\nMin-distance : $Configs{samechrom_wiggle} bp\nRead Distribution upper limit: $Configs{lopsidedupper} X\nRead Distribution lower limit: $Configs{lopsidedlower} X\n";
if ( $Configs{splitReads} !~ /^[0-9,.E]+$/ ) {
	die "ERROR: Split Reads value $Configs{splitReads} is not numeric.  Acceptable arguments are: 'auto', 'highprecision', 'highsensitivity', or any number\n";
} 
if ( $Configs{spancutoff} !~ /^[0-9,.E]+$/ ) {
	die "ERROR: Spanning Reads value $Configs{spancutoff} is not numeric.  Acceptable arguments are: 'auto', 'highprecision', 'highsensitivity', or any number\n";
} 

# primary data format; $chr1_pos1_chr2_pos2_strandA_strandB[0/1/2][0-RL]
	#where strand is + or -
	#and [0/1/2] indicates left-side/right-side of fusion/non-split reads
	#0-Read length starts at the fusion site =0 and expands outwards from there, to pos2+RL on right side, pos1-RL on left side.
	# in most cases, we will use + strand notation for positions.
print "\nNow catologuing all chimeric reads\n"; 
open JUNCTION, "<$junction" or die $!; 
EXITHERE: while (my $x = <JUNCTION>) {
	my @line = split(/\s+/, $x); 
##some filtering 
	next if ($line[$col_chrA] eq "chrM");
	next if ($line[$col_chrB] eq "chrM");
	next if ($line[$col_chrA] eq "MT");
	next if ($line[$col_chrB] eq "MT");
	next if ($line[$col_chrA] =~ m/GL*/);
	next if ($line[$col_chrB] =~ m/GL*/);
	next if ($line[$col_overlapL] > $Configs{overlapLimit});
	next if ($line[$col_overlapR] > $Configs{overlapLimit});	

#calculate read length (where read length == the length of one pair of the sequencing if paired end)
	if ($linecount < 1 ) {
		my $cigarA=$line[$col_cigarA];
		my $cigarB=$line[$col_cigarB];
		my $lengthA = &splitCigar($cigarA);
		my $lengthB = &splitCigar($cigarB);
		if ($lengthA == $lengthB) {
			$readlength=$lengthA;
			print "Read length appears to be $readlength\n";
		}	
		elsif ($lengthA == (2*$lengthB)) {
			$readlength=$lengthB;
			print "Read length appears to be $readlength\n";
		}
		elsif ($lengthB == (2*$lengthA)) {
			$readlength=$lengthA;
			print "Read length appears to be $readlength\n";
		}
		else { print "read length error, please check input\nCigar String $cigarA (length $lengthA ) and $cigarB (length $lengthB ) indicate different lengths\nWill try again with the next line of your junctions file\n"; 
			$readlength=100;
			$linecount=-1;
		}
	}
#Skip antibody Parts regions: ab files have chr stripped if they have it.  so i'll strip it from the reads here. 
	my $chrA = $line[$col_chrA] ; 
	my $chrB = $line[$col_chrB] ;
	$chrA =~ s/^chr//; $chrB =~ s/^chr// ;  
        foreach my $z (0..$abindex) {
                no warnings 'uninitialized' ;
                if ($AbParts[$z][0]{$chrA} <= $line[$col_FusionposA] && $line[$col_FusionposA] <= $AbParts[$z][1]{$chrA}) {
                        #print "pos1 match\n";
                        foreach my $y (0..$abindex) {
                                if ($AbParts[$y][0]{$chrB} <= $line[$col_FusionposB] && $line[$col_FusionposB]<= $AbParts[$y][1]{$chrB}) {
                                        #print "Skipping $line[$col_chrA]:$line[$col_FusionposA] $line[$col_chrB]:$line[$col_FusionposB]";
                                        next EXITHERE;
                                }
                        }
                }
        }
	
#Create two 'names' and check if they exist.  Checking the written + reverse allows us to collapse reads on opposite strands
	my $fusionname=$line[$col_chrA] . "__" . $line[$col_FusionposA] . "__" . $line[$col_chrB] . "__" . $line[$col_FusionposB] . "__" . $line[$col_strandA] . "__" . $line[$col_strandB] ; 
	my $invStrandA = &reversestrand($line[$col_strandA]);
	my $invStrandB = &reversestrand($line[$col_strandB]);
	my $fusionnameInv=$line[$col_chrB] . "__" . $line[$col_FusionposB] . "__" . $line[$col_chrA] . "__" . $line[$col_FusionposA] . "__" . $invStrandB . "__" . $invStrandA ;
	## chrA_pos1_+ fused to chrB_pos2_+ equals chrB_pos2_- fused to chrA_pos_- etc.  
	##check the existence
	if (exists $fusions{$fusionname}) {
		&supportCigar(@line, $fusionname, "1");

	}
	elsif (exists $fusions{$fusionnameInv}) {
	  #because this is the reverse compliment of the already indexed read, we'll feed in a rearranged line from Chimeric.out.junction, with the strands flipped.
		$chrA=$line[$col_chrB];
		my $posA=$line[$col_FusionposB];
		my $strandA = &reversestrand($line[$col_strandB]); 
		$chrB=$line[$col_chrA];
		my $posB=$line[$col_FusionposA];
		my $strandB = &reversestrand($line[$col_strandA]);
		#6 7,8,9 unchanged/unimportant here
		my $startposA = $line[$col_startposB];
		my $cigarA = $line[$col_cigarB];
		my $starposB = $line[$col_startposA];
		my $cigarB = $line[$col_cigarA];
		#print "@line\n";
		#print "$chrA $posA $strandA $chrB $posB $strandB $line[7] $line[8] $line[9] $startposA $cigarA $starposB $cigarB\n";
		&supportCigar($chrA, $posA, $strandA, $chrB, $posB, $strandB, $line[6], $line[7], $line[8], $line[9], $startposA, $cigarA, $starposB, $cigarB, $fusionnameInv, "2" );
	}
	else {
		#create the array in the fusions hash
		for my $x (0..($readlength-1)) {
			$fusions{$fusionname}[0][$x] =0; #jxn crossing read support (Left side)
			$fusions{$fusionname}[1][$x] =0; #jxn crossing read support (Right side)
		}
		$fusions{$fusionname}[2][0] = 0; #jxn spanning read support on the strands as named
		$fusions{$fusionname}[2][1] = 0; # strand distribution (jxn crossing reads in 'fusionname' orientaiton with first listed chrm on the left)
		$fusions{$fusionname}[2][2] = 0; # strand distribution (jxn crossing reads in 'fusionnameInv' orientation with first listed chrm on the right)
		$fusions{$fusionname}[2][3] = 0; # A chrom anchored (for split reads, the pair lies on chromosome A)
		$fusions{$fusionname}[2][4] = 0; # B chrom anchored (for split reads, the matepair lies on chromosome B)
		$fusions{$fusionname}[2][5] = 0; #jxn spanning read support inverse strands
		&supportCigar(@line, $fusionname, "1");
	}
	$linecount++;
	#print "$fusionname\t$fusions{$fusionname}[0][0]\t$fusions{$fusionname}[1][0]\n";
	#if ($linecount > 10 ) { die; }
}
my $numbkeys = scalar keys %fusions;
print "Finished catologing fusion reads, now processing over $numbkeys potential fusion sites\n";
close(JUNCTION);
##Post Processing and Filtering
##currently, the process goes: create file.summary this file gets annotated (file.summary.annotated), and then this annotated file gets filtered and reduced to a new file, named file.summary
##it's somewhat confusing, but I think the output is most understandable this way.  
#SETUP
my $fusioncounter =0;
open (SUMMTEMP, ">$outsummtemp") or die; 
print SUMMTEMP "Partner1\tPartner2\tScore\tSpanningReads\tSplitReads\tTopsideCrossing\tBottomsideCrossing\tChromAAnchors\tChromBAnchors\tUniqueSupportLeft\tUniqueSupportRight\tKurtosis\tSkew\tLeftAnchor\tRightAnchor\tTopsideSpanning\tBottomsideSpanning\n";
my $keycount ;

#Join and Evaluate Fusions
for my $key (keys %fusions) {#go through all 'fusions'
	$keycount++ ;
	#first filter by read support
	if ($fusions{$key}[0][0] >=$Configs{splitReads} && $fusions{$key}[1][0] >=$Configs{splitReads}) {
                my @keyarray=split(/__/, $key); #0:chrm1 1:pos 2:chr2 3:pos2 4:strand 5:strand 
                 #skip same-chrom proximal fusions
		if ($keyarray[0] eq $keyarray[2] && (abs($keyarray[1]-$keyarray[3])<=$Configs{samechrom_wiggle}) ){
               		next;
                }
		#skip lopsided fusions (ie all the read support is on one side)
		if ( ($fusions{$key}[2][1]+0.1)/($fusions{$key}[2][2]+0.1) >= $Configs{lopsidedupper} || ($fusions{$key}[2][1]+0.1)/($fusions{$key}[2][2]+0.1) <= $Configs{lopsidedlower}) {
			next;
		}
		my $topspancount = $fusions{$key}[2][0];
		my $bottomspancount = $fusions{$key}[2][5];
		##now we need to do a broad check for spanning reads that didn't map to the exact fusion location
		# I do this by doing a rough check for close locations.  This mostly works, but gets messy with larger values of $Configs{wiggle}, and when fusion sites are near each other on the same chromosome.  
		# in those cases, take results with a grain of salt.
		if ($Configs{pairedend} eq "TRUE") {  
			for my $key2 (keys %fusions) { #cycle through all the keys again
				next if ($key eq $key2); #skip itself
				if ($fusions{$key2}[2][0] >= 1 || $fusions{$key2}[2][5] >=1 ) { #we are only really interested in sites with spanning fusions
					my @key2array=split(/__/, $key2); #see above for indices
					next if ($key2array[0] eq $key2array[2] && (abs($key2array[1]-$key2array[3])<=$Configs{samechrom_wiggle}) ); #skip same chrom proximal
					#check if the fusion from keyarray (has jxn crossing) has the same coordinates (within $Configs{wiggle} bp) as $keyarray2
					if ($keyarray[4] eq $key2array[4] && $keyarray[5] eq $key2array[5] && $keyarray[0] eq $key2array[0] && $keyarray[2] eq $key2array[2] && (abs($keyarray[1]-$key2array[1])<=$Configs{wiggle}) && (abs($keyarray[3]-$key2array[3])<=$Configs{wiggle}) ) {
						#print "1: $key2 spans $key reads: $fusions{$key2}[2][0] sum before: $fusions{$key}[2][0]\n";
						$topspancount += $fusions{$key2}[2][0];
						$bottomspancount += $fusions{$key2}[2][5]; 
					}
					#check the inverse fusion
					elsif (&reversestrand($keyarray[4]) eq $key2array[5] && &reversestrand($keyarray[5]) eq $key2array[4] && $keyarray[0] eq $key2array[2] && $keyarray[2] eq $key2array[0] && (abs($keyarray[1]-$key2array[3])<=$Configs{wiggle}) && (abs($keyarray[3]-$key2array[1])<=$Configs{wiggle}) ) {
						$topspancount += $fusions{$key2}[2][5];
						$bottomspancount += $fusions{$key2}[2][0];
						#print "2: $key2 spans $key reads: $fusions{$key2}[2][0] sum before: $fusions{$key}[2][0]\n";
					}
				}
			}
		}
		#Second, filter on spanning read pairs
		my $spancount = $topspancount + $bottomspancount ; 
		if ($spancount >= $Configs{spancutoff}) { 
			#next get an estimate of the 'unique reads' mapped by looking at how many unique read support values there are
			my @array0; my @array1;
			my $leftanchor ; my $rightanchor; 
	                for my $x (0..($readlength-1)) { 
				#cycle across possible support positions.  create arrays of # of reads of support at each position.  (skip 0 read support) Also note largest overlap in read support
   	                	if ($fusions{$key}[0][$x] != 0) {
					push (@array0, $fusions{$key}[0][$x]);	$leftanchor = $x;}
				if ($fusions{$key}[1][$x] != 0) {
					push (@array1, $fusions{$key}[1][$x]); $rightanchor = $x;}
        	        }
                	my %count0; my %count1;
        	        @count0{@array0} =(); @count1{@array1} =(); #turn the arrays into hashes.
	                my $unique0=scalar keys %count0; my $unique1=scalar keys %count1; #count the unique hash indices. 
			my @kurtosisarray;
               		for my $x (reverse (15..($readlength-16))) { push (@kurtosisarray, $fusions{$key}[0][$x]);}
			for my $x (15..($readlength-16)) { push (@kurtosisarray, $fusions{$key}[1][$x]);}
			my ($skew, $kurtosis)=&kurtosis(@kurtosisarray); #still calculating kurtosis, but not sure how useful it is.  
			#filter by the number of these unique reads
                	if ($unique0 >= $Configs{uniqueReads} && $unique1 >= $Configs{uniqueReads}) {
				$fusioncounter++;
				my $position1; my $position2; 
				my $splitreads = $fusions{$key}[2][1] + $fusions{$key}[2][2] ;
				# STAR outputs in columns 2,4 the 1st base of the intron around a fusion site.  I think the 1st base that we see is more intuitive.  So here I adjust.  
				($position1, $position2) = &adjustposition($keyarray[1],$keyarray[4],$keyarray[3],$keyarray[5]);
				#0:split reads, 1:topsidesplit, 2:bottomsidesplit 3:spanreads 4;topspan 5;bottomspan 6:skew 7:chr1 8;loc1 9;strand1 10;chr2; 11;loc2; 12;strand2
				#The score is a work in progress.  
				my $score = &fusionScore($splitreads,$fusions{$key}[2][1],$fusions{$key}[2][2],$spancount,$topspancount, $bottomspancount,$skew,$keyarray[0],$position1,$keyarray[4],$keyarray[2],$position2,$keyarray[5]);
				##Output. This can be changed as needed, but the first two columns need to be chr1:pos:str.  They are fed into coordinates2genes.sh for gene annotation later.  
				print SUMMTEMP "$keyarray[0]:$position1:$keyarray[4]\t$keyarray[2]:$position2:$keyarray[5]\t$score\t$spancount\t$splitreads\t$fusions{$key}[2][1]\t$fusions{$key}[2][2]\t$fusions{$key}[2][3]\t$fusions{$key}[2][4]\t$unique0\t$unique1\t$kurtosis\t$skew\t$leftanchor\t$rightanchor\t$topspancount\t$bottomspancount\n";
				print "Filtered fusions count:$fusioncounter, searched $keycount\n";
			}
		}
	}
}
print "Total fusions passing read thresholds found: $fusioncounter\nThese fusions will now be filtered based on annotations\n";
close (SUMMTEMP);

print "-fusions-from-star.pl complete.\n";


exit(0);




### BEGIN SUBROUTINES ###
##also some reference info on cigar operators:
##cigar operators:
# M match
# I insertion (into the reference)
# D deletion from ref
# N skipped over ref seq
# S soft clipping
# H hard clipping
# P padding (silent deletion from padded ref)

# below subroutine modified from http://bioinfomative.blogspot.com/2012/07/parsing-cigar-and-md-fields-of-sambam.html
# Given a Cigar string return an estimate of the read length
sub splitCigar {
	no warnings 'uninitialized';
	my $string = $_[0];
	my @split = split(//, $string);
	my $count="";
	my %matches=();
	foreach my $x (0..$#split) {
		#print "$x: $split[$x]\n";
		if ($split[$x] =~ m/[0-9]/ ) {
			#print "number detected\t";
			$count .= $split[$x];
			#print "$count\n";
		}
		else {
			#print "non number $split[$x]\t";
			$matches{$split[$x]} += $count;
			$count=0;
			#print "$split[$x] : $matches{$split[$x]}\n";
		}
	}
	$matches{"S"} + $matches{"M"} + $matches{"I"};
}
sub supportCigar { #input: SJ line 
##this goes through a line and fills in two arrays (which are part of a hash of array of arrays).
# The main goal is to get read support for the readlength around a fusion.  This fills in arrays outside those bounds, but that data is meaningless
# the reason is that only array points defined are global.  those created in the subroutine, stay here, so read support for two fusions at 1000nt outside the fusion will be concatenated. 
# I could fix this by making the above definitions arbitrarily large, but the values still wouldn't hold meaningful information.  
	my $fusionname = $_[$numbcolumns];
##deal with non-split reads, exit
        if ($_[$col_jxntype] eq "-1") {
		if ($_[($numbcolumns+1)] eq "1") {
			#mates are same orientation as the name
	        	$fusions{$fusionname}[2][0]++;
        		return;
		}
		if ($_[($numbcolumns+1)] eq "2")	{
			#mates are in the inverse orientation wrt the name
			$fusions{$fusionname}[2][5]++;
			return;
		}
	}
##count read support by side of fusion:
	$fusions{$fusionname}[2][$_[($numbcolumns+1)]]++;
##Left side of the fusion
  ## - strand
	if ($_[$col_strandA] eq "-") {
		my $supportindex = 0;  #support index should start at 0 and move up to read length.  this is the index that traverses the reference seq to add support.
		my $cigarA = $_[$col_cigarA];
		my @split = split(//, $cigarA);
		my $count="";
		EXITER: foreach my $x (0..$#split) { ##separate cigar terms into ind. characters
			if ($split[$x] =~ m/[0-9]/ ) {
				$count .= $split[$x]; #rejoin numbers
			}
			else { #when we have a complete cigar term
				if ($split[$x] eq "S") { } #do nothing for softclipping
				elsif ($split[$x] eq "M") { #on match, add read support for length of cigar M
					foreach my $y ($supportindex .. ($count+$supportindex)) {
						#print "adding 1 to $supportindex + $y which was $fusions{$fusionname}[0][$y]\n";
						$fusions{$fusionname}[0][$y]++; 
					}
					$supportindex = $supportindex + $count ; #move the support index
				}
				#for padding and skipped ref (usually intron) and deletions move the support index without adding support
				#elsif ($split[$x] eq "p") { $supportindex =$supportindex + $count ;}
				elsif ($split[$x] eq "p") { $count=""; $fusions{$fusionname}[2][3]++; last EXITER ;}
				elsif ($split[$x] eq "N") { $supportindex =$supportindex + $count ;}
				elsif ($split[$x] eq "D") { $supportindex =$supportindex + $count ;}
				elsif ($split[$x] eq "I") { }#do nothing for insertion.  should count negatively, but no easy way to do this. 
				$count="";
			}
		}
	}
  ## + strand
        if ($_[$col_strandA] eq "+") {
                my $supportindex = ($_[$col_FusionposA] - $_[$col_startposA]);  #support index should start at read length and move down to zero.  this is the index that traverses the reference seq to add support.
                #print "supportindex: $supportindex\t";
		my $cigarA = $_[$col_cigarA];
                my @split = split(//, $cigarA);
                my $count="";
                my $pskip=0; 
		#pskip helps me deal with split/span support.  when the cigar has a P, it means that we're matching R1 + R2 to reference.  But we're only concerned with the partner on the fusion
		#On left side +/- you want the cigar after/before p.
		#On right side +/- you want the cigar before/after p. 
                if ($cigarA =~ m/p/ ) {
                        $pskip = 1;
                }		
		foreach my $x (0..$#split) { ##separate cigar terms
                        if ($split[$x] =~ m/[0-9,-]/ ) {
                                $count .= $split[$x];
                        }
                        else { #when we have a complete cigar term
                                if ($split[$x] eq "S") { } #do nothing for softclipping
                                elsif ($split[$x] eq "M") { #on match, add read support for length of cigar M
                                        if ($pskip ne "1") {
						foreach my $y (reverse (($supportindex-$count) .. $supportindex)) {
	                                        	$fusions{$fusionname}[0][$y]++;
        	                                }
                			}
		                        $supportindex = $supportindex - $count ; #move the support index
                                }
                                #for padding and skipped ref (usually intron) and deletions move the support index without adding support
                                elsif ($split[$x] eq "p") { $supportindex =$supportindex - $count ; $pskip =0; $fusions{$fusionname}[2][3]++;}
                                elsif ($split[$x] eq "N") { $supportindex =$supportindex - $count ;}
                                elsif ($split[$x] eq "D") { $supportindex =$supportindex - $count ;}
                                elsif ($split[$x] eq "I") { }#do nothing for insertion.  should count negatively, but no easy way to do this. 
                        	#print "$supportindex\t$count\t$split[$x]\n";
				$count="";
                        }
                }
        }
	#print "we have fusion name $fusionname\n";
	#foreach my $f (0..($readlength-1)) {
	#	print "$fusions{$fusionname}[0][$f] ";
	#}
	#print "\n";
##Right side of the fusion
  ## + strand
        if ($_[$col_strandB] eq "+") {
                my $supportindex = 0;  #support index should start at 0 and move up to read length.  this is the index that traverses the reference seq to add support.
                my $cigarB = $_[$col_cigarB];
                my @split = split(//, $cigarB);
                my $count="";
                EXITER: foreach my $x (0..$#split) { ##separate cigar terms
                        if ($split[$x] =~ m/[0-9]/ ) {
                                $count .= $split[$x];
                        }
                        else { #when we have a complete cigar term
                                if ($split[$x] eq "S") { } #do nothing for softclipping
                                elsif ($split[$x] eq "M") { #on match, add read support for length of cigar M
                                        foreach my $y ($supportindex .. ($count+$supportindex)) {
                                                $fusions{$fusionname}[1][$y]++;
                                        }
                                        $supportindex = $supportindex + $count ; #move the support index
                                }
                                #for padding and skipped ref (usually intron) and deletions move the support index without adding support
                                #elsif ($split[$x] eq "p") { $supportindex =$supportindex + $count ;}
                               	elsif ($split[$x] eq "p") { $count=""; $fusions{$fusionname}[2][4]++; last EXITER ;}
				elsif ($split[$x] eq "N") { $supportindex =$supportindex + $count ;}
                                elsif ($split[$x] eq "D") { $supportindex =$supportindex + $count ;}
                                elsif ($split[$x] eq "I") { }#do nothing for insertion.  should count negatively, but no easy way to do this. 
                                $count="";
                        }
                }
        }
  ## - strand
	if ($_[$col_strandB] eq "-") {
                my $supportindex = ($_[$col_FusionposB] - $_[$col_startposB]);  #support index should start at read length and move down to zero.  this is the index that traverses the reference seq to add support.
                my $cigarB = $_[$col_cigarB];
                my @split = split(//, $cigarB);
                my $count="";
		my $pskip=0; 
		if ($cigarB =~ m/p/ ) {
			$pskip = 1;
		}
                foreach my $x (0..$#split) { ##separate cigar terms
                        if ($split[$x] =~ m/[0-9,-]/ ) {
                                $count .= $split[$x];
                        }
                        else { #when we have a complete cigar term
                                if ($split[$x] eq "S") { } #do nothing for softclipping
                                elsif ($split[$x] eq "M") { #on match, add read support for length of cigar M
                                        if ($pskip ne "1" ) {
						foreach my $y (reverse (($supportindex-$count) .. $supportindex)) {
                                	                $fusions{$fusionname}[1][$y]++;
                                       		}
					}
                                        $supportindex = $supportindex - $count ; #move the support index
                                }
                                #for padding and skipped ref (usually intron) and deletions move the support index without adding support
                                elsif ($split[$x] eq "p") { $supportindex =$supportindex - $count ; $pskip = 0;$fusions{$fusionname}[2][4]++;}
                                elsif ($split[$x] eq "N") { $supportindex =$supportindex - $count ;}
                                elsif ($split[$x] eq "D") { $supportindex =$supportindex - $count ;}
                                elsif ($split[$x] eq "I") { }#do nothing for insertion.  should count negatively, but no easy way to do this. 
                                #print "$supportindex\t$count\t$split[$x]\n";
                                $count="";
                        }
                }
        } 
}



sub reversestrand {
	if ($_[0] eq "+"){
		return "-";
	}
	elsif ($_[0] eq "-"){
		return "+";
	}
}

#this sub taken from user jkahn on perlmonks: http://www.perlmonks.org/?node_id=197793
sub revcompl { # operates on all elements passed in
  my (@dna) = @_;
  my @done;
  foreach my $segment (@dna) {
    my $revcomp = reverse($segment);
    $revcomp =~ tr/ACGTacgt/TGCAtgca/;
    push @done, $revcomp;
  }
  return @done; # or reverse @done;  # what's best semantics?
}
sub adjustposition { #takes in 0pos, 1strand, 2pos 3strand
	my $position1;
	my $position2;
	if ($_[1] eq "+") {
		$position1 = $_[0] -1;
	}
	elsif ($_[1] eq "-") {
		$position1 = $_[0] +1;
	}
	if ($_[3] eq "+") {
		$position2 = $_[2] +1;
	}
	elsif ($_[3] eq "-") {
		$position2 = $_[2] -1;
	}
	return ($position1, $position2); 
}
sub unadjustposition { #reverse the effect of adjustposition
	#takes in 0pos, 1strand, 2pos 3strand
	my $position1;
        my $position2;
        if ($_[1] eq "+") {
                $position1 = $_[0] +1;
        }
        elsif ($_[1] eq "-") {
                $position1 = $_[0] -1;
        }
        if ($_[3] eq "+") {
                $position2 = $_[2] -1;
        }
        elsif ($_[3] eq "-") {
                $position2 = $_[2] +1;
        }
        return ($position1, $position2);
}

#credit: http://www.bagley.org/~doug/shootout/  slash http://dada.perl.it/shootout/moments.perl.html
sub kurtosis { 
	my @nums=@_;
	#print "@nums\n"; 
	my $sum = 0;
	foreach (@nums) { $sum += $_ }
	my $n = scalar(@nums);
	my $mean = $sum/$n;
	my $average_deviation = 0;
	my $standard_deviation = 0;
	my $variance = 0;
	my $skew = 0;
	my $kurtosis = 0;
	foreach (@nums) {
   		my $deviation = $_ - $mean;
	 	$average_deviation += abs($deviation);
    		$variance += $deviation**2;
    		$skew += $deviation**3;
    		$kurtosis += $deviation**4;
	}
	$average_deviation /= $n;
	$variance /= ($n - 1);
	$standard_deviation = sqrt($variance);
	#print "variance:$variance ";
	if ($variance) {
		$skew /= ($n * $variance * $standard_deviation);
	    	$kurtosis = $kurtosis/($n * $variance * $variance) - 3.0;
		$kurtosis = substr($kurtosis, 0,5);
		$skew = substr($skew, 0,5);
	}
	#print "kurtosis:$kurtosis\n";
	return ($skew, $kurtosis);
}
sub fusionScore {
	my @params=@_; #0:split reads, 1:topsidesplit, 2:bottomsidesplit 3:spanreads 4;topspan 5;bottomspan 6:skew 7:chr1 8;loc1 9;strand1 10;chr2; 11;loc2; 12;strand2
	my $splitscore;
	# Score from Split Reads
	if ($params[1] >= $params[2]) {
		$splitscore = $params[0]/(($params[1]+1)/($params[2]+1));
	}
	else {$splitscore = $params[0]/(($params[2]+1)/($params[1]+1)); }
	my $spanscore;
	#Score from non-Split Reads
	if ($params[4] >= $params[5]) {
		$spanscore = $params[3]/(($params[4]+1)/($params[5]+1));
	}
	else { $spanscore = $params[3]/(($params[5]+1)/($params[4]+1)); }
	my $basescore = $splitscore/$Configs{splitscoremod} + $spanscore/$Configs{spanscoremod} ; 
	#Skew Penalty
	if ($params[6] >=0.25 ) { $basescore = $basescore*$Configs{skewpenalty}; }	
	#Read-through penalty 
	if ($params[7] eq $params[10] && $params[9] eq $params[12] ) {
		my $dist = abs($params[8] - $params[11]);
		my $penalty = 20000/$dist;
		$basescore = $basescore - $penalty*$basescore ; 
	}
	$basescore = sprintf "%.1f", $basescore; 
	return($basescore); 
}
