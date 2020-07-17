#!/usr/bin/perl
#
# C struct dependencies grapher
# (done in mind to ease the linux kernel comprehension)
#
# Copyright (C) 2006 Mathieu GELI <mathieu.geli@gmail.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2, or (at your option)
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.



use Tie::IxHash; # for sorted-by-add-time hashes
use GraphViz;    # for bitmap graph generation
use Getopt::Std; # command-line parsing
use Regexp::Common qw /balanced/;

my $rootinc;
my $entry_file;
my $outfile;
my $width;
my $height;
my $include_max_depth;
my $tree_max_depth;
my $viewer;
my $total_nodes = 0;
my $tmp_depth = 0;
my $heuristic;
my @includes_manual;
my $ident = '\~?_*[a-zA-Z][a-zA-Z0-9_]*';
my $fontname="times";

tie my %includes, "Tie::IxHash";
tie my %tmp_includes, "Tie::IxHash";
tie my %structs, "Tie::IxHash";
my %structs_copy = %{$structs};

sub usage {
  print << "EOF";
StructViz (C) 2006 Mathieu GELI <mathieu.geli@gmail.com>
StructViz (C) 2018-2020 Balbir Singh <bsingharora@gmail.com>

usage :
\t-h this help
\t-e entry_file (default: "linux/ip.h")
\tThe graph will take its roots on the structs of that file
\t-o outfile (default: "/tmp/graph.svg")
\t-d output in dot format
\tthe svg output file
\t-W width (default: 20)
\t-H height (default: 20)
\tdimensions of the outfile in regard that 10 stands for ~1000px
\t-r rootinc (default: "/usr/src/linux/include")
\tthe includes root directory, entry_file is accessed with rootinc
\t-i include_max_depth (default: 10)
\tthe maximum depth of the tree formed by chained include files.
\t-t tree_max_depth (default: 5)
\tthe maximum depth of the tree formed by chained structs
\t-v viewer (default: ee from Electric Eyes pacakge)
\t-a filelist (e.g "linux/ip.h linux/if_arp.h")
\t-E list of entry files, useful for subsystems
\t-f font name
For special cases were structs definitions are missing

\texample : $0 -e "linux/netlink.h" -o "netlink.svg" -W 30 -H 30

EOF
exit;
}

# let's do some options parsing
%opt=();
getopts("he:o:W:H:r:i:t:v:a:E:df:", \%opt);
if (keys %opt == 0 && $#ARGV != -1) { usage(); } # handle unknow option
usage() if $opt{h};

if ($opt{a}) {
  @includes_manual = split(" ", $opt{a});
}

if ($opt{E}) {
  @entry_files = split(/\s+/, $opt{E});
  #print "-E".$opt{E}."\n";
}

if ($opt{r}) {
  if (-e $opt{r}) {
    $rootinc = $opt{r};
  }
  else {
    print "Hey buddy, you at least need the kernel includes files.\n";
    exit;
  }
}
else {
  $rootinc="/usr/src/linux/include";
}

if ($opt{f}) {
    $fontname = $opt{f};
}

if ($opt{e}) {
  if (-e "$rootinc/$opt{e}") {
    $entry_file = $opt{e};
  }
  else {
    print "I cannot find file $rootinc/$opt{e}\n";
    exit;
  }
}
else {
  $entry_file = "linux/ip.h";
}

if ($opt{o}) {
  $outfile = $opt{o};
}
else {
  $outfile = "/tmp/graph.svg";
}

if ($opt{W}) {
  # 60 is the limit for me because of the RAM...
  $width = check_int($opt{W}, 1, 6000, "invalid range for window width");
}
else {
  $width = 30;
}

if ($opt{H}) {
  $height = check_int($opt{H}, 1, 6000, "invalid range for window height");
}
else {
  $height = 30;
}

if ($opt{i}) {
  $include_max_depth = check_int($opt{i}, 0, 1000, "invalid range for include depth");
}
else {
  $include_max_depth = 10;
}

if ($opt{t}) {
  $tree_max_depth = check_int($opt{t}, 1, 30, "invalid range for tree depth");
}
else {
  $tree_max_depth = 5;
}

if ($opt{v}) {
  $viewer = $opt{v};
}
else {
  $viewer = "ee";
}

$heuristic = int(($tree_max_depth+1)*($tree_max_depth)/2)+1;

# options summary
print << "EOF";
($0 -h for help)
options summary
\trootinc    : $rootinc
\tentry_file : $entry_file
\toutfile    : $outfile
\twidth      : $width
\theight     : $height
\tinc_depth  : $include_max_depth
\ttree_depth : $tree_max_depth
\theuristic  : $heuristic
EOF

sub check_int {
  my $int = shift;
  my $min = shift;
  my $max = shift;
  my $errmsg = shift;

  if ($int >= $min and $int <= $max) {
    return $int; #  awkward, references ?
  }
  else {
    print $errmsg . "\n";
    exit;
  }
}

sub file_get_structs {
  my $file = shift;
  open(FH, "$rootinc/$file");
  $_ = $/; undef($/);
  my $content = <FH>;
  $/ = $_;

  # some cleaning up
  $content =~ s/\/\*(.*?)\*\///ges;
  $content =~ s/\n\t*\n/\n/gs;
  # $content =~ s/\#(define|ifdef|endif|if|error|elif)(.*?)\n//ges;
  $content =~ s/\#error.*?\n//ges;
  $content =~ s/enum \{(.*?)}//ges;

  # detect struct definition
  while ($content =~ m/struct\s+($ident)\s*$RE{balanced}{-parens=>'{}'}.*?;/gs) {
    my $struct_name = $1;
    my $struct_content = $2;
    #print "** $struct_name **\n";
    #print $struct_content . "\n";
    if (not exists $structs{$struct_name}) {
      # print "$struct_name from $file stored.\n";
      my @triplet = ($struct_content, -1, $file);
      $structs{$struct_name} = \@triplet;
    }
    else {
      true;
      # print "file_get_structs: $struct_name from $file seems to be alreay defined in $structs{$struct_name}[2].\n";
    }
  }
  while ($content =~ m/typedef\s+struct\s*$RE{balanced}{-parens=>'{}'}\s*($ident)\s*((__attribute__.*?)|(__cache*))*?;/gs) {
    my $struct_name = $2;
    my $struct_content = $1;
    #print "** $struct_name **\n";
    #print $struct_content . "\n";
    if (not exists $structs{$struct_name}) {
      # print "$struct_name from $file stored.\n";
      my @triplet = ($struct_content, -1, $file);
      $structs{$struct_name} = \@triplet;
    }
    else {
      true;
      # print "file_get_structs: $struct_name from $file seems to be alreay defined in $structs{$struct_name}[2].\n";
    }
  }
  while ($content =~ m/#define\s+(.*?)\s+(.*?)\s*\n/gs) {
    my $struct_name = $2;
    my $new_name = $1;
    #print "** $struct_name  $new_name **\n";
    if (exists $structs{$struct_name}) {
      my @triplet = ($structs{$struct_name}[0], -1, $file);
      $structs{$new_name} = \@triplet;
    }
    else {
      true;
      # print "file_get_structs: $struct_name from $file seems to be alreay defined in $structs{$struct_name}[2].\n";
    }
  }
  #print $content."T";
  while ($content =~ m/typedef\s+($ident)\s*($ident)*?;/gs) {
    my $struct_name = $2;
    my $struct_content = $structs{$1}[0];
    # print "** $struct_name **\n";
    #print "typedef".$struct_content . "\n";
    if (not exists $structs{$struct_name}) {
      # print "$struct_name from $file stored.\n";
      my @triplet = ($struct_content, -1, $file);
      $structs{$struct_name} = \@triplet;
    }
    else {
      true;
      # print "file_get_structs: $struct_name from $file seems to be alreay defined in $structs{$struct_name}[2].\n";
    }
  }
    close FH;
  }

  sub file_get_includes {
    my $file = shift;
    my $depth = shift;
    my %local_includes;
    open(FH, "$rootinc/$file");
    $_ = $/; undef($/);
    my $content = <FH>;
    $/ = $_;
    while ($content =~ m/\#include\s+(<|\")(\S+)(>|\")/gs) {
      # print $2 . "\n";
      $local_includes{$2} = $depth + 1;
    }
    close FH;
    return %local_includes;
  }

  sub struct_get_structs {
    my $code = shift;
    my @struct_idents;
    # print $code;
    #print $s2."\n";
    foreach my $s (keys %structs_copy) {
      # print "s is".$s."\n";
      foreach my $s2 ($s) {
        # print $2."---\n";
        while ($code =~ m/.*($s2).*?;/gs) {
          push @struct_idents, $1;
          # print $1."\t";
        }
      }
    }
    return @struct_idents;
  }

  # first pass : store all included files and get their structs definitons
  print "pass 1 : Parsing sources...\n";
  file_get_structs($entry_file);
  if ($includes{$entry_file} >= $include_max_depth) {
    print "max depth reached. jumping to pass2.\n";
    goto pass2;
  }

  %tmp_includes = file_get_includes($entry_file, 0);

  # FIXME : those files are not scanned so we add them manually
  foreach (@includes_manual) {
    $tmp_includes{$_} = 0; # depth 0 means we simulate the #include
    # exist in $entry_file
  }
  foreach $file (keys %tmp_includes) {
    if (not exists $includes{$file}) {
      # print "pushing $file, \t\tdepth : $tmp_includes{$file}\n";
      $includes{$file} = $tmp_includes{$file};
      file_get_structs($file);
    }
  }

  @_includes = keys %includes;   # hack to have a loop on a growing hash
  foreach(@_includes) {          # the problem was : looping with (keys %hash) was using
    my $cur_file = $_;         # a past snapshot of the keys, not the growing ones
    # print "cur file : $cur_file\n";
    # print "*parsing* $cur_file, current depth: $includes{$cur_file}\n";
    if ($includes{$cur_file} >= $include_max_depth) {
      print "max depth reached. jumping to pass2.\n";
      goto pass2;
    }

    %tmp_includes = file_get_includes($cur_file, $includes{$cur_file});
    foreach $file (keys %tmp_includes) {
      # looking if the file is already standing in the global array and with a bigger depth counter
      if (not exists $includes{$file} || $includes{$file} > $includes{$cur_file}+1) {
        # print "pushing $file \t\tdepth :\t$tmp_includes{$file}\n";
        file_get_structs($file);
        # printf "recensed include files : %d\n", $#includes;
        $includes{$file} = $tmp_includes{$file};
        @_includes = keys %includes; # update the array we are looping on
      }
    }
  }

 pass2:
  print "pass 2 : Building graph dependencies...\n";
  my $g = GraphViz->new(node => {shape => 'box'}, rankdir => true, width => $width, height => $height);

  foreach my $entry_file (@entry_files) {
    # first pass : store all included files and get their structs definitons
    print "pass 1 : Parsing sources...$entry_file\n";
    file_get_structs($entry_file);
    if ($includes{$entry_file} >= $include_max_depth) {
        print "max depth reached. jumping to pass3.\n";
        goto pass3;
    }

    %tmp_includes = file_get_includes($entry_file, 0);

    # FIXME : those files are not scanned so we add them manually
    foreach (@includes_manual) {
        $tmp_includes{$_} = 0; # depth 0 means we simulate the #include
        # exist in $entry_file
    }
    foreach $file (keys %tmp_includes) {
        if (not exists $includes{$file}) {
            # print "pushing $file, \t\tdepth : $tmp_includes{$file}\n";
            $includes{$file} = $tmp_includes{$file};
            file_get_structs($file);
        }
    }

    @_includes = keys %includes;   # hack to have a loop on a growing hash
    foreach(@_includes) {          # the problem was : looping with (keys %hash) was using
        my $cur_file = $_;         # a past snapshot of the keys, not the growing ones
        # print "cur file : $cur_file\n";
        # print "*parsing* $cur_file, current depth: $includes{$cur_file}\n";
        if ($includes{$cur_file} >= $include_max_depth) {
            print "max depth reached. jumping to pass3.\n";
            goto pass3;
        }

        %tmp_includes = file_get_includes($cur_file, $includes{$cur_file});
        foreach $file (keys %tmp_includes) {
            # looking if the file is already standing in the global array and with a bigger depth counter
            if (not exists $includes{$file} || $includes{$file} > $includes{$cur_file}+1) {
                # print "pushing $file \t\tdepth :\t$tmp_includes{$file}\n";
                file_get_structs($file);
                # printf "recensed include files : %d\n", $#includes;
                $includes{$file} = $tmp_includes{$file};
                @_includes = keys %includes; # update the array we are looping on
            }
        }
    }
 }

  # second pass : loop over the structs and build the dep graph
  pass3:
  # stats
  print "gathered " . (keys %includes). " include files.\n";
  print "gathered " . (keys %structs) . " structure defintions.\n";

  %structs_copy = %structs;
  #print "S".%structs, "SC".%structs_copy;
  while (($k,$v) = each(%structs)) {
    # for structs on the top-level
    #print "$k".$v."\n";
    if (($structs{$k}[2] eq $entry_file)
        || (grep(/$structs{$k}[2]/, @entry_files))) {
      $tmp_depth = 0;
      #print "Building graph for".$k."---\n";
      $ret = build_graph($k); # let's go for a ride	
      #print "Built graph for".$v."---\n";
    }
  }

  # breadth-first search algorithm
  sub build_graph {
    my @queue;
    my $edge = shift;
    # print "* enqueueing $edge\n";
    unshift(@queue, $edge);
    $queue_len = $#queue;
    $tmp_depth++;
    while ($queue_len >= 0) {
      my $tmp_edge = pop(@queue);
      #print "dequeueing and marking $tmp_edge\n";

      my $label = $structs{$tmp_edge}[0];
      $label =~ s/\n/\\r/g;
      # $label =~ s/({|})//g;
      $total_nodes++;
      $g->add_node($tmp_edge, label => "$tmp_edge\\l" . $label, width => 2.5, fontname => $fontname);

      $structs{$tmp_edge}[1] = 0; # we mark the edge
      # create the sons list
      # limit the depth for the search

      my @sons = struct_get_structs($structs{$tmp_edge}[0]);
      $tmp_depth++;
      #print "Sons".@sons."\n\n";
      # if ($tmp_depth >= $heuristic && not grep(/$structs{$tmp_edge}[2]/, @includes_manual)) {
      if ($tmp_depth >= $heuristic) {
        return 1;
      }
      foreach(@sons) {
        my $son = $_;
        if (exists $structs{$son} && $structs{$son}[1] == -1) { # if not marked enqueue
          # print "enqueuing $son\n";
          $g->add_edge($tmp_edge => $son);
          unshift(@queue, $son);
        }
        elsif ($struct{$son}[1] == 0 && not $son eq $tmp_edge) {
          $g->add_edge($tmp_edge => $son);
        }
      }
      $queue_len = $#queue;
      # print "QUEUE_LEN".$queue_len;
    }
  }
  # stats

  end:
  print "effective node number : $total_nodes\n";
  print "pass 3 : Displaying graph...\n";

  if ($opt{d}) {
    @output = $g->as_text;
    open(FH, '>', $outfile);
    print FH @output;
    close(FH);
  } else {
      $g->as_svg($outfile);
  }
  #$g->as_text($outfile);
  #system("$viewer $outfile");

  1;

  __END__

=head1 NAME

structviz - C struct dependencies grapher

=head1 SYNOPSIS

  structviz [-h] [-r rootfile] [-e entry_file] [-o outfile] [-W width]
  [-H height] [-i include_max_depth] [-t tree_max_depth] [-v viewer]
  [-a include_list]

=head1 DESCRIPTION

  Structviz

