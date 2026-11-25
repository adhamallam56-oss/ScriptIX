#!/usr/bin/perl
# scriptix {{PKGVERSION}} - reads SCAP files (data streams, XCCDF, OVAL) for the scriptix command.
# Plain Perl 5.8 or newer, no modules: AIX and most Linux systems have it already.
# It makes the same scripts as the ScriptIX app. The checks themselves run in sh and awk.
use strict;

my $VERSION = '{{VERSION}}';
my $NS12 = 'http://checklists.nist.gov/xccdf/1.2';
my $OVALSYS = 'http://oval.mitre.org/XMLSchema/oval-definitions-5';
my $MAX = 400 * 1024 * 1024;
my $TAB = "\t";

sub fail { my $m = join('', @_); utf8::encode($m) if utf8::is_utf8($m); print STDERR "scriptix: $m\n"; exit 1 }

# ================================================================ XML
# node: [0 local name, 1 namespace, 2 attributes (text, then hash), 3 children, 4 start, 5 end, 6 raw name, 7 attribute order, 8 scope, 9 file]
my %FILES;   # file -> its bytes
my %ENT = (lt => '<', gt => '>', amp => '&', quot => '"', apos => "'");

sub ent {
  my ($s) = @_;
  utf8::decode($s) if $s =~ /[\x80-\xff]/;
  if (index($s, '&') >= 0) {
    $s =~ s/&(#x[0-9A-Fa-f]{1,6}|#[0-9]{1,7}|[A-Za-z]+);/
      my $e = $1;
      $e =~ m{^#x(.*)} ? pack('U', hex($1)) : $e =~ m{^#(.*)} ? pack('U', $1) : exists $ENT{$e} ? $ENT{$e} : die "unknown entity &$e;\n"/ge;
  }
  return $s;
}

sub parse_xml {
  my ($file) = @_;
  open(my $h, '<', $file) or die "cannot read $file: $!\n";
  binmode($h);
  die "$file is too big\n" if -s $h > $MAX;
  my $t; { local $/; $t = <$h>; } close($h);
  $t = '' unless defined $t;
  $t =~ s/^\xef\xbb\xbf//;
  die "$file: UTF-16 files are not supported\n" if $t =~ /^(?:\xff\xfe|\xfe\xff)/;
  if ($t =~ /^<\?xml[^>]*?encoding\s*=\s*["']([^"']+)["']/) {
    my $e = lc $1;
    if ($e eq 'iso-8859-1' || $e eq 'latin1') { utf8::encode($t) }
    elsif ($e ne 'utf-8' && $e ne 'utf8' && $e ne 'us-ascii' && $e ne 'ascii') { die "$file: encoding $1 is not supported\n" }
  }
  $t =~ s/\r\n?/\n/g;
  $FILES{$file} = \$t;
  my ($root, @stack);
  my $cur;
  my %top = (xml => 'http://www.w3.org/XML/1998/namespace', '' => '');
  my $scope = \%top;
  my $len = length $t;
  pos($t) = 0;
  while (pos($t) < $len) {
    if ($t =~ /\G([^<]+)/gc) {
      if ($cur) { push @{$cur->[3]}, $1 } else { die "$file: not an XML file\n" if $1 =~ /\S/ }
    }
    elsif ($t =~ /\G<\/([^\s>]+)\s*>/gc) {
      die "$file: bad XML near </$1>\n" unless $cur && $cur->[6] eq $1;
      $cur->[5] = pos($t);
      pop @stack; $cur = $stack[-1]; $scope = $cur ? $cur->[8] : \%top;
    }
    elsif ($t =~ /\G<!--/gc) { $t =~ /\G.*?-->/gcs or die "$file: bad XML (comment)\n" }
    elsif ($t =~ /\G<!\[CDATA\[(.*?)\]\]>/gcs) { my $c = $1; $c =~ s/&/&amp;/g; push @{$cur->[3]}, $c if $cur }
    elsif ($t =~ /\G<\?/gc) { $t =~ /\G.*?\?>/gcs or die "$file: bad XML\n" }
    elsif ($t =~ /\G<!DOCTYPE/gc) { die "$file: files with a DTD are refused\n" }
    elsif ($t =~ /\G<([^\s>\/!?]+)((?:[^>"'\/]+|"[^"]*"|'[^']*'|\/(?!>))*)(\/?)>/gc) {
      my ($raw, $at, $empty, $start) = ($1, $2, $3, $-[0]);
      my $sc = $scope;
      if (index($at, 'xmlns') >= 0) {
        $sc = { %$scope };
        while ($at =~ /(?:^|\s)xmlns(?::([^\s=]+))?\s*=\s*(?:"([^"]*)"|'([^']*)')/g) {
          $sc->{defined $1 ? $1 : ''} = ent(defined $2 ? $2 : $3);
        }
      }
      my ($pre, $name) = $raw =~ /^([^:]*):(.*)$/ ? ($1, $2) : ('', $raw);
      die "$file: unknown prefix $pre\n" unless exists $sc->{$pre};
      my $n = [$name, $sc->{$pre}, $at, [], $start, 0, $raw, undef, $sc, $file];
      if ($cur) { push @{$cur->[3]}, $n } elsif ($root) { die "$file: two root elements\n" } else { $root = $n }
      if ($empty) { $n->[5] = pos($t) }
      else { push @stack, $n; $cur = $n; $scope = $sc; die "$file: nested too deep\n" if @stack > 500 }
    }
    else { die "$file: bad XML at byte " . pos($t) . "\n" }
  }
  die "$file: the file is cut off\n" if $cur;
  die "$file: not an XML file\n" unless $root;
  return $root;
}

sub attrs {
  my ($n) = @_;
  return $n->[2] if ref $n->[2];
  my (%h, @o);
  my $s = $n->[2];
  while ($s =~ /([^\s=]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g) {
    my ($k, $v) = ($1, defined $2 ? $2 : $3);
    $v =~ tr/\t\n/  /;
    $h{$k} = ent($v); push @o, $k;
  }
  $n->[2] = \%h; $n->[7] = \@o;
  return \%h;
}
sub at { my ($n, $a) = @_; my $h = ref $n->[2] ? $n->[2] : attrs($n); return defined $h->{$a} ? $h->{$a} : '' }
sub at_ns { my ($n, $local) = @_; my $h = attrs($n); for my $k (@{$n->[7]}) { return $h->{$k} if $k =~ /:\Q$local\E$/ && $k !~ /^xmlns:/ } return '' }
sub kids { return grep { ref $_ } @{$_[0][3]} }
sub els { my ($n, $name) = @_; return grep { ref $_ && $_->[0] eq $name } @{$n->[3]} }
sub el { my ($n, $name) = @_; return undef unless $n; for (@{$n->[3]}) { return $_ if ref $_ && $_->[0] eq $name } return undef }
sub val { my ($n) = @_; return '' unless $n; my $s = ''; for (@{$n->[3]}) { $s .= ref $_ ? val($_) : ent($_) } return $s }
sub trim { my ($s) = @_; $s =~ s/^\s+//; $s =~ s/\s+$//; return $s }
sub text { my ($n) = @_; return '' unless $n; my $s = val($n); $s =~ s/\s+/ /g; return trim($s) }
sub walk { my ($n, $f) = @_; $f->($n); for (@{$n->[3]}) { walk($_, $f) if ref $_ } }   # the node itself and everything below
sub is_true { return $_[0] eq 'true' || $_[0] eq '1' }
sub is_false { return $_[0] eq 'false' || $_[0] eq '0' }
sub cut { my ($s, $n) = @_; return length($s) > $n ? substr($s, 0, $n) . '...' : $s }
sub short_id { my ($id, $m) = @_; my $i = rindex($id, $m); return $i >= 0 ? substr($id, $i + length $m) : $id }
sub strip_hash { my ($s) = @_; $s =~ s/^#+//; return $s }

# the source text of a node, with the namespace declarations it inherits
sub raw_node {
  my ($n) = @_;
  my $s = substr(${$FILES{$n->[9]}}, $n->[4], $n->[5] - $n->[4]);
  my ($head) = $s =~ /^(<[^\s>\/]+(?:[^>"']|"[^"]*"|'[^']*')*>)/;
  my $add = '';
  for my $p (sort keys %{$n->[8]}) {
    next if $p eq 'xml' || ($p eq '' && $n->[8]{''} eq '');
    my $a = $p eq '' ? 'xmlns' : "xmlns:$p";
    next if $head =~ /\s\Q$a\E\s*=/;
    my $u = $n->[8]{$p}; utf8::encode($u) if utf8::is_utf8($u);
    $u =~ s/&/&amp;/g; $u =~ s/"/&quot;/g; $u =~ s/</&lt;/g;
    $add .= " $a=\"$u\"";
  }
  $s =~ s/^(<[^\s>\/]+)/$1$add/;
  utf8::decode($s);
  return $s;
}

# ================================================================ the files of a source
my %S;   # kind version root bench oval dicts ocil benchmarks by tried dir

sub oval_version { my $g = el($_[0], 'generator'); my $v = $g ? el($g, 'schema_version') : undef; return $v ? trim(val($v)) : '' }

sub load_source {
  my ($file, $bid) = @_;
  %S = (kind => '', version => '', oval => [], dicts => [], ocil => [], benchmarks => [], by => {}, tried => {});
  $S{dir} = $file =~ m{^(.*)/[^/]*$} ? ($1 eq '' ? '/' : $1) : '.';
  my $r = $S{root} = parse_xml($file);
  if ($r->[0] eq 'asset-report-collection') {   # ARF: the scanned file is inside
    my ($ds, $b);
    walk($r, sub { my ($n) = @_; $ds = $n if !$ds && $n->[0] eq 'data-stream-collection'; $b = $n if !$b && $n->[0] eq 'Benchmark' && $n->[1] eq $NS12 });
    $r = $S{root} = $ds || $b || $r;
  }
  my $k = $r->[0];
  if ($k eq 'data-stream-collection') { read_ds($r, $bid) }
  elsif ($k eq 'Benchmark') { $S{kind} = 'XCCDF benchmark'; $S{bench} = $r; my $i = index($r->[1], 'xccdf/'); $S{version} = $i < 0 ? '' : substr($r->[1], $i + 6) }
  elsif ($k eq 'oval_definitions') { $S{kind} = 'OVAL definitions'; push @{$S{oval}}, $r; $S{version} = oval_version($r) }
  elsif ($k eq 'Tailoring') { $S{kind} = 'XCCDF tailoring' }
  elsif ($k eq 'TestResult') { $S{kind} = 'XCCDF results' }
  elsif ($k eq 'asset-report-collection') { $S{kind} = 'ARF results' }
  elsif ($k eq 'oval_results') { $S{kind} = 'OVAL results' }
  elsif ($k eq 'cpe-list') { $S{kind} = 'CPE dictionary'; push @{$S{dicts}}, $r }
  elsif ($k eq 'ocil') { $S{kind} = 'OCIL questionnaires'; push @{$S{ocil}}, $r }
  elsif ($k eq 'cvrfdoc') { $S{kind} = 'CVRF advisory' }
  else { $S{kind} = $k }
  if ($S{bench} && $S{kind} eq 'XCCDF benchmark') {
    my $oval;   # ssg-x-xccdf.xml comes with ssg-x-cpe-dictionary.xml
    walk($S{bench}, sub { $oval = at($_[0], 'href') if !defined $oval && $_[0][0] eq 'check-content-ref' && at($_[0], 'href') =~ /-oval\.xml$/ });
    if (defined $oval) { $oval =~ s/-oval\.xml/-cpe-dictionary.xml/g; find_file($oval) }
  }
}

sub has_node { my ($l, $n) = @_; for (@$l) { return 1 if $_ == $n } return 0 }

sub read_ds {
  my ($root, $bid) = @_;
  $S{kind} = 'SCAP data stream';
  my (%parts, @order);
  for my $c (kids($root)) {
    next unless $c->[0] eq 'component' || $c->[0] eq 'extended-component';
    my ($body) = kids($c);
    if ($body) { push @order, at($c, 'id') unless $parts{at($c, 'id')}; $parts{at($c, 'id')} = $body }
  }
  for my $ds (els($root, 'data-stream')) {
    $S{version} = at($ds, 'scap-version') if $S{version} eq '';
    my (@refs, %body);
    walk($ds, sub { push @refs, $_[0] if $_[0][0] eq 'component-ref' });
    for my $r (@refs) { my $t = strip_hash(at_ns($r, 'href')); $body{at($r, 'id')} = $parts{$t} if $parts{$t} }
    for my $r (@refs) {
      walk($r, sub {
        my ($u) = @_; return unless $u->[0] eq 'uri';
        my $b = $body{strip_hash(at($u, 'uri'))};
        $S{by}{at($u, 'name')} = $b if $b && !$S{by}{at($u, 'name')};
      });
      my $b = $body{at($r, 'id')} or next;
      if ($b->[0] eq 'Benchmark') {
        my $id = at($b, 'id');
        push @{$S{benchmarks}}, $id unless grep { $_ eq $id } @{$S{benchmarks}};
        $S{bench} = $b if !$S{bench} || (defined $bid && $id eq $bid);
      }
      elsif ($b->[0] eq 'oval_definitions') { push @{$S{oval}}, $b unless has_node($S{oval}, $b) }
      elsif ($b->[0] eq 'cpe-list') { push @{$S{dicts}}, $b unless has_node($S{dicts}, $b) }
      elsif ($b->[0] eq 'ocil') { push @{$S{ocil}}, $b unless has_node($S{ocil}, $b) }
    }
  }
  for my $k (@order) {
    my $v = $parts{$k};
    next unless $v->[0] eq 'oval_definitions' && !has_node($S{oval}, $v);
    push @{$S{oval}}, $v; $S{by}{$k} = $v unless $S{by}{$k};
  }
}

# the document a check refers to: from the data stream, or a file in the same folder
sub find_file {
  my ($href) = @_;
  $href = strip_hash($href);
  return @{$S{oval}} == 1 ? $S{oval}[0] : undef if $href eq '';
  return $S{by}{$href} if $S{by}{$href};
  return undef if $S{tried}{lc $href}++;
  return undef if $href =~ m{[/\\]} || $href eq '..' || $href eq '.';
  my $p = "$S{dir}/$href";
  return undef unless -f $p && -s $p <= $MAX;
  my $r = eval { parse_xml($p) } or return undef;
  $S{by}{$href} = $r;
  if ($r->[0] eq 'oval_definitions') { push @{$S{oval}}, $r }
  elsif ($r->[0] eq 'cpe-list') { push @{$S{dicts}}, $r }
  elsif ($r->[0] eq 'ocil') { push @{$S{ocil}}, $r }
  return $r;
}

# ================================================================ OVAL library
my (%OV, @OVIDS, $OVFILES, $OVDEFS);
sub refresh_oval {
  return if defined $OVFILES && $OVFILES == @{$S{oval}};
  $OVFILES = @{$S{oval}}; %OV = (); @OVIDS = (); $OVDEFS = 0;
  for my $root (@{$S{oval}}) {
    for my $sec (kids($root)) {
      next unless $sec->[0] =~ /^(?:definitions|tests|objects|states|variables)$/;
      for my $e (kids($sec)) {
        my $id = at($e, 'id');
        next if $id eq '' || $OV{$id};
        $OV{$id} = $e; push @OVIDS, $id;
        $OVDEFS++ if $sec->[0] eq 'definitions';
      }
    }
  }
}

# ================================================================ OVAL -> the lines the awk engine reads (the app's OvalCompiler)
my %KINDS = map { my ($k, $o, $s) = split /\|/; $k => [$o, $s] } grep { /\S/ } split /\n/, <<'EOF';
independent:textfilecontent54|filepath path filename pattern instance|filepath path filename pattern instance text subexpression
independent:family||family
independent:environmentvariable58|pid name|pid name value
independent:environmentvariable|name|name value
independent:variable|var_ref|var_ref value
independent:filehash58|filepath path filename hash_type|filepath path filename hash_type hash
unix:file|filepath path filename|filepath path filename type user_id group_id size suid sgid sticky uread uwrite uexec gread gwrite gexec oread owrite oexec has_extended_acl
unix:uname||machine_class node_name os_name os_release os_version processor_type
unix:password|username|username password user_id group_id gcos home_dir login_shell
unix:shadow|username|username password chg_lst chg_allow chg_req exp_warn exp_inact exp_date flag encrypt_method
unix:sysctl|name|name value
unix:symlink|filepath|filepath canonical_path
unix:interface|name|name type inet_addr flag
unix:process58|command_line pid|command_line pid ppid ruid user_id
unix:runlevel|service_name runlevel|service_name runlevel start kill
linux:dpkginfo|name|name arch epoch version release evr
linux:rpminfo|name|name arch epoch version release evr signature_keyid extended_name
linux:partition|mount_point|mount_point device fs_type mount_options
linux:systemdunitproperty|unit property|unit property value
linux:systemdunitdependency|unit|unit dependency
linux:inetlisteningservers|protocol local_address local_port|protocol local_address local_port local_full_address
linux:selinuxboolean|name|name current_status pending_status
linux:selinuxsecuritycontext|filepath path filename|filepath path filename user role type
aix:fileset|flstinst|flstinst level state description
aix:oslevel||maintenance_level
aix:no|tunable|tunable value
aix:interim_fix|vuid|vuid label state
EOF
my %OPS = map { $_ => 1 } ('', 'equals', 'not equal', 'case insensitive equals', 'case insensitive not equal', 'greater than', 'greater than or equal',
  'less than', 'less than or equal', 'pattern match', 'bitwise and', 'bitwise or', 'subset of');
my %TYPES = map { $_ => 1 } ('', qw(string int float boolean evr_string debian_evr_string version fileset_revision ios_version ipv4_address binary));

my (@IR, %DONE, @TODO, $NODES, $EXT);

sub oesc { my ($s) = @_; return $s unless $s =~ /[\\\t\n\r]/; $s =~ s/\\/\\\\/g; $s =~ s/\t/\\t/g; $s =~ s/\n/\\n/g; $s =~ s/\r/\\r/g; return $s }
sub line { push @IR, join("\t", @_) }
sub safe { my ($s) = @_; $s =~ tr/\t\n /___/; return $s }
sub use_id { my ($id) = @_; push @TODO, $id if $id ne '' && !$DONE{$id}++; return safe($id) }
sub new_node {
  my ($type, $op, $neg, @c) = @_;
  my $id = 'n' . ++$NODES;
  line($type, $id, $op, $neg ? '1' : '0') unless @c;
  while (@c) { line($type, $id, $op, $neg ? '1' : '0', splice(@c, 0, 20)) }
  return $id;
}
# check and platform trees: [definition, operator, negate, children]
sub ir_check { my ($n) = @_; if (defined $n->[0]) { use_id($n->[0]); return 'E' . safe($n->[0]) } my @k = map { ir_check($_) } @{$n->[3]}; return 'K' . new_node('K', $n->[1], $n->[2], @k) }
sub ir_platform { my ($n) = @_; if (defined $n->[0]) { use_id($n->[0]); return ($n->[2] ? '!' : '') . 'D' . safe($n->[0]) } my @k = map { ir_platform($_) } @{$n->[3]}; return 'C' . new_node('C', $n->[1], $n->[2], @k) }

sub compile_oval {
  my ($root, $plat, $ext) = @_;
  @IR = (); %DONE = (); @TODO = (); $NODES = 0; $EXT = $ext;
  if ($plat) { my $p = ir_platform($plat); line('P', $p) }
  if ($root) { my $c = ir_check($root); line('R', $c) } else { line('R', 'M') }
  while (@TODO) { ir_entity(shift @TODO) }
  return join('', map { "$_\n" } @IR);
}
sub ir_entity {
  my ($id) = @_;
  my $e = $OV{$id} or return;
  my $n = $e->[0];
  if ($n eq 'definition') { my $c = el($e, 'criteria'); my $k = $c ? 'C' . ir_criteria($c) : ''; line('D', safe($id), at($e, 'class'), $k) }
  elsif ($n =~ /_test$/) { ir_test($id, $e) }
  elsif ($n =~ /_object$/) { ir_object($id, $e) }
  elsif ($n =~ /_state$/) { ir_state($id, $e) }
  elsif ($n =~ /_variable$/) { ir_variable($id, $e) }
}
sub ir_criteria {
  my ($e) = @_;
  my @k;
  for my $k (kids($e)) {
    my $neg = is_true(at($k, 'negate')) ? '!' : '';
    if ($k->[0] eq 'criteria') { push @k, 'C' . ir_criteria($k) }
    elsif ($k->[0] eq 'criterion') { push @k, $neg . 'T' . use_id(at($k, 'test_ref')) }
    elsif ($k->[0] eq 'extend_definition') { push @k, $neg . 'D' . use_id(at($k, 'definition_ref')) }
  }
  my $op = at($e, 'operator');
  return new_node('C', $op eq '' ? 'AND' : $op, is_true(at($e, 'negate')), @k);
}
sub or_else { return $_[0] eq '' ? $_[1] : $_[0] }
sub ir_test {
  my ($id, $e) = @_;
  my $kind = substr($e->[0], 0, -5);
  my $comment = oesc(substr(at($e, 'comment'), 0, 200));
  if ($kind eq 'unknown') { line('T', safe($id), 'unknown', '', '', '', '', $comment); return }
  my $p = test_problem($e, $kind);
  if (defined $p) { line('T', safe($id), '?', '', '', '', $p, $comment); return }
  my $o = el($e, 'object');
  my @f = ('T', safe($id), $kind, or_else(at($e, 'check_existence'), 'at_least_one_exists'), at($e, 'check'), or_else(at($e, 'state_operator'), 'AND'),
    use_id($o ? at($o, 'object_ref') : ''), $comment);
  push @f, use_id(at($_, 'state_ref')) for els($e, 'state');
  line(@f);
}
sub test_problem {
  my ($t, $kind) = @_;
  my $fam = $t->[1] =~ /^[^#]*#(.*)$/ ? $1 : '';
  my $known = $KINDS{"$fam:$kind"} or return $kind;
  my $or = el($t, 'object');
  my $o = $OV{$or ? at($or, 'object_ref') : ''} or return "$kind (object missing)";
  my %oe = map { $_ => 1 } split / /, $known->[0];
  my %se = map { $_ => 1 } split / /, $known->[1];
  my $p = object_problem($o, $kind, \%oe, \%se, 0);
  return $p if defined $p;
  for (els($t, 'state')) { $p = state_problem(at($_, 'state_ref'), $kind, \%se); return $p if defined $p }
  return undef;
}
sub state_problem {
  my ($id, $kind, $ents) = @_;
  my $s = $OV{$id} or return "$kind (state missing)";
  for my $e (kids($s)) {
    next if $e->[0] eq 'notes' || $e->[0] eq 'Signature';
    return "$kind.$e->[0]" unless $ents->{$e->[0]};
    my $p = entity_problem($e);
    return "$kind.$e->[0] $p" if defined $p;
  }
  return undef;
}
sub entity_problem { my ($e) = @_; return at($e, 'operation') unless $OPS{at($e, 'operation')}; return at($e, 'datatype') unless $TYPES{at($e, 'datatype')}; return undef }
sub object_problem {
  my ($o, $kind, $oe, $se, $depth) = @_;
  return "$kind (nested too deep)" if $depth > 8;
  return "$kind (wrong object)" if $o->[0] ne "${kind}_object";
  my $set = el($o, 'set');
  return set_problem($set, $kind, $oe, $se, $depth) if $set;
  for my $e (kids($o)) {
    my $n = $e->[0];
    next if $n eq 'notes' || $n eq 'Signature';
    if ($n eq 'filter') { my $p = state_problem(trim(val($e)), $kind, $se); return $p if defined $p; next }
    if ($n eq 'behaviors') { return "$kind recurse up" if at($e, 'recurse_direction') eq 'up'; next }
    return "$kind.$n" unless $oe->{$n};
    my $p = entity_problem($e);
    return "$kind.$n $p" if defined $p;
    my $op = at($e, 'operation');
    return "$kind.$n $op" if ($n eq 'filepath' || $n eq 'path') && $op !~ /^(?:|equals|pattern match)$/;
    return "$kind.pattern $op" if $n eq 'pattern' && $op ne 'pattern match';
  }
  return undef;
}
sub set_problem {
  my ($set, $kind, $oe, $se, $depth) = @_;
  for my $c (kids($set)) {
    my $p;
    if ($c->[0] eq 'set') { $p = set_problem($c, $kind, $oe, $se, $depth + 1) }
    elsif ($c->[0] eq 'filter') { $p = state_problem(trim(val($c)), $kind, $se) }
    elsif ($c->[0] eq 'object_reference') { my $o = $OV{trim(val($c))}; $p = $o ? object_problem($o, $kind, $oe, $se, $depth + 1) : "$kind (object missing)" }
    return $p if defined $p;
  }
  return undef;
}
sub ir_object {
  my ($id, $e) = @_;
  my $kind = substr($e->[0], 0, -7);
  my $set = el($e, 'set');
  if ($set) { ir_set(safe($id), $kind, $set); return }
  line('O', safe($id), $kind);
  for my $x (kids($e)) {
    my $n = $x->[0];
    if ($n eq 'notes' || $n eq 'Signature') { next }
    elsif ($n eq 'behaviors') { my $h = attrs($x); for my $k (@{$x->[7]}) { my $l = $k; $l =~ s/^.*://; line('OB', safe($id), $l, $h->{$k}) } }
    elsif ($n eq 'filter') { line('OF', safe($id), or_else(at($x, 'action'), 'exclude'), use_id(trim(val($x)))) }
    elsif ($n eq 'var_ref') { line('OE', safe($id), $n, 'equals', 'string', 'all', 'lit', use_id(trim(val($x)))) }
    else { my ($src, $v) = ir_source($x); line('OE', safe($id), $n, or_else(at($x, 'operation'), 'equals'), at($x, 'datatype'), or_else(at($x, 'var_check'), 'all'), $src, $v) }
  }
}
sub ir_set {
  my ($id, $kind, $set) = @_;
  line('O', $id, $kind);
  my (@m, $k);
  for my $c (kids($set)) {
    if ($c->[0] eq 'object_reference') { push @m, use_id(trim(val($c))) }
    elsif ($c->[0] eq 'set') { my $sub = "$id." . ++$k; ir_set($sub, $kind, $c); push @m, $sub }
  }
  line('OF', $id, or_else(at($_, 'action'), 'exclude'), use_id(trim(val($_)))) for els($set, 'filter');
  line('OS', $id, or_else(at($set, 'set_operator'), 'UNION'), @m);
}
sub ir_state {
  my ($id, $e) = @_;
  line('S', safe($id), or_else(at($e, 'operator'), 'AND'));
  for my $x (kids($e)) {
    next if $x->[0] eq 'notes' || $x->[0] eq 'Signature';
    my ($src, $v) = ir_source($x);
    line('SE', safe($id), $x->[0], or_else(at($x, 'operation'), 'equals'), at($x, 'datatype'), or_else(at($x, 'entity_check'), 'all'), or_else(at($x, 'var_check'), 'all'), $src, $v);
  }
}
sub ir_source {
  my ($x) = @_;
  my $v = at($x, 'var_ref');
  return ('var', use_id($v)) if $v ne '';
  return ('nil', '') if is_true(at_ns($x, 'nil'));
  return ('lit', oesc(val($x)));
}
sub ir_variable {
  my ($id, $e) = @_;
  my $sid = safe($id);
  if ($e->[0] eq 'constant_variable') { line('V', $sid, 'const', ''); line('VV', $sid, oesc(val($_))) for els($e, 'value') }
  elsif ($e->[0] eq 'external_variable') { line('V', $sid, 'ext', ''); if ($EXT->{$id}) { line('VV', $sid, oesc($_)) for @{$EXT->{$id}} } }
  elsif ($e->[0] eq 'local_variable') {
    my ($b) = grep { $_->[0] ne 'notes' && $_->[0] ne 'Signature' } kids($e);
    my $c = $b ? ir_component($b) : ir_bad();
    line('V', $sid, 'local', $c);
  }
  else { my $c = ir_bad(); line('V', $sid, 'local', $c) }
}
sub ir_bad { my $id = 'x' . ++$NODES; line('X', $id, 'bad'); return $id }
sub ir_component {
  my ($e) = @_;
  my $id = 'x' . ++$NODES;
  my $n = $e->[0];
  my $k = sub { return map { ir_component($_) } grep { $_->[0] ne 'notes' } kids($e) };
  my $put = sub { line('X', $id, @_) };
  if ($n eq 'literal_component') { $put->('lit', oesc(val($e))) }
  elsif ($n eq 'variable_component') { $put->('var', use_id(at($e, 'var_ref'))) }
  elsif ($n eq 'object_component') { if (at($e, 'record_field') ne '') { $put->('bad') } else { $put->('obj', use_id(at($e, 'object_ref')), at($e, 'item_field')) } }
  elsif ($n =~ /^(?:concat|unique|count|merge|escape_regex|glob_to_regex)$/) { $put->($n, $k->()) }
  elsif ($n eq 'arithmetic') { $put->($n, at($e, 'arithmetic_operation'), $k->()) }
  elsif ($n eq 'split') { $put->($n, $k->(), oesc(at($e, 'delimiter'))) }
  elsif ($n eq 'regex_capture') { $put->($n, $k->(), oesc(at($e, 'pattern'))) }
  elsif ($n eq 'substring') { $put->($n, $k->(), at($e, 'substring_start'), at($e, 'substring_length')) }
  elsif ($n eq 'begin' || $n eq 'end') { $put->($n, $k->(), oesc(at($e, 'character'))) }
  elsif ($n eq 'time_difference' && at($e, 'format_2') eq 'seconds_since_epoch') { $put->($n, or_else(at($e, 'format_1'), 'year_month_day'), at($e, 'format_2'), $k->()) }
  else { $put->('bad') }
  return $id;
}

# ================================================================ XCCDF
my %D;   # id title description version status file target rules groups profiles platforms values valueorder plain overrides prebuilt

sub weight { my $w = at($_[0], 'weight'); return $w =~ /^\s*\+?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\s*$/ ? $w + 0 : 1 }

sub load_doc {
  my ($o) = @_;
  load_source($o->{file}, $o->{benchmark});
  my ($base) = $o->{file} =~ m{([^/]*)$};
  %D = (id => '', title => '', description => '', version => '', status => '', file => $base, target => 'any', rules => [], groups => [],
    profiles => [], platforms => [], values => {}, valueorder => [], plain => {}, overrides => {});
  if ($S{bench}) { load_benchmark() }
  elsif (@{$S{oval}}) { load_oval($base) }
  else {
    die "this is a tailoring file. Give the benchmark, and this one with --tailoring\n" if $S{kind} eq 'XCCDF tailoring';
    die "this is a results file\n" if $S{kind} =~ / results$/;
    die "no XCCDF rules in this file. Use a SCAP data stream (ssg-*-ds.xml), an XCCDF benchmark or an OVAL file\n";
  }
  load_tailoring($o->{tailoring}) if defined $o->{tailoring};
  if (defined $o->{tailoring} && !defined $o->{profile}) { my @t = grep { $_->{tailored} } @{$D{profiles}}; $o->{profile} = $t[0]{id} if @t == 1 }
  for my $pair (@{$o->{set} || []}) {
    $pair =~ /^([^=]+)=(.*)$/s or die "--set needs NAME=VALUE\n";
    my ($n, $v) = ($1, $2);
    my ($id) = grep { $_ eq $n || /_value_\Q$n\E$/ } @{$D{valueorder}};
    die "value not found: $n\n" unless defined $id;
    $D{overrides}{$id} = $v;
  }
}

sub load_benchmark {
  my $b = $S{bench};
  $D{id} = at($b, 'id'); $D{title} = text(el($b, 'title')); $D{description} = cut(text(el($b, 'description')), 1500); $D{version} = text(el($b, 'version'));
  $D{status} = join(', ', map { text($_) . (at($_, 'date') ne '' ? ' ' . at($_, 'date') : '') } els($b, 'status'));
  $D{platforms} = [grep { $_ ne '' } map { at($_, 'idref') } els($b, 'platform')];
  $D{plain}{at($_, 'id')} = val($_) for els($b, 'plain-text');
  read_items($b, undef);
  die "no XCCDF rules were found in this benchmark\n" unless @{$D{rules}};
  my %seen;
  for my $r (@{$D{rules}}) { for my $c (@{$r->{checks}}) { walk($c, sub { if ($_[0][0] eq 'check-content-ref') { my $h = at($_[0], 'href'); find_file($h) unless $seen{$h}++ } }) } }
  refresh_oval();
  $D{profiles} = [map { read_profile($_, 0) } els($b, 'Profile')];
  resolve($_) for @{$D{profiles}};
  my %abs = map { at($_, 'id') => is_true(at($_, 'abstract')) } reverse els($b, 'Profile');
  $D{profiles} = [grep { !$abs{$_->{id}} } @{$D{profiles}}];
  my %p; my @rp = grep { !$p{$_}++ } map { @{$_->{platforms}} } @{$D{rules}};
  splice(@rp, 50) if @rp > 50;
  my $s = lc(join(' ', @{$D{platforms}}) . ' ' . join(' ', @rp));
  $D{target} = $s =~ /:ibm:aix/ ? 'AIX' : $s =~ /:sun:|:oracle:solaris/ ? 'SunOS' : $s =~ /:hp:hp-ux/ ? 'HP-UX' : $s =~ /freebsd|openbsd|netbsd/ ? 'BSD'
    : $s =~ /linux|cpe:\/o:/ || $D{title} =~ /linux/i ? 'Linux' : $D{title} =~ /AIX/ ? 'AIX' : 'any';
}

sub read_items {
  my ($parent, $group) = @_;
  for my $e (kids($parent)) {
    if ($e->[0] eq 'Group') {
      my $g = { id => at($e, 'id'), title => text(el($e, 'title')), on => !is_false(at($e, 'selected')), weight => weight($e), parent => $group,
        platforms => [map { at($_, 'idref') } els($e, 'platform')], cluster => at($e, 'cluster-id') };
      push @{$D{groups}}, $g;
      read_items($e, $g);
    }
    elsif ($e->[0] eq 'Rule') {
      next if is_true(at($e, 'abstract')) || is_true(at($e, 'hidden'));
      my $id = at($e, 'id');
      my $t = text(el($e, 'title'));
      push @{$D{rules}}, { id => $id, short => short_id($id, '_rule_'), title => $t ne '' ? $t : $id, severity => at($e, 'severity'), role => at($e, 'role'),
        on => !is_false(at($e, 'selected')), weight => weight($e), parent => $group, node => $e, cluster => at($e, 'cluster-id'),
        platforms => [map { at($_, 'idref') } els($e, 'platform')], requires => [map { [split ' ', at($_, 'idref')] } els($e, 'requires')],
        conflicts => [map { at($_, 'idref') } els($e, 'conflicts')], checks => [grep { $_->[0] eq 'check' || $_->[0] eq 'complex-check' } kids($e)],
        fixes => [els($e, 'fix')], idents => [els($e, 'ident')] };
    }
    elsif ($e->[0] eq 'Value') {
      my $v = { id => at($e, 'id'), sel => {}, selorder => [], lists => {} };
      for my $x (els($e, 'value')) {
        my $s = at($x, 'selector');
        if ($s eq '') { $v->{def} = val($x) } else { push @{$v->{selorder}}, $s unless exists $v->{sel}{$s}; $v->{sel}{$s} = val($x) }
      }
      $v->{lists}{at($_, 'selector')} = [map { val($_) } els($_, 'item')] for els($e, 'complex-value');
      push @{$D{valueorder}}, $v->{id} unless $D{values}{$v->{id}};
      $D{values}{$v->{id}} = $v;
    }
  }
}

sub read_profile {
  my ($x, $tailored) = @_;
  my $id = at($x, 'id'); my $t = text(el($x, 'title'));
  my $p = { id => $id, tailored => $tailored, title => $t ne '' ? $t : short_id($id, '_profile_'), description => cut(text(el($x, 'description')), 1500), extends => at($x, 'extends'), ops => [] };
  for my $e (kids($x)) {
    my $n = $e->[0];
    if ($n eq 'select') { push @{$p->{ops}}, ['select', at($e, 'idref'), or_else(at($e, 'selected'), 'true')] }
    elsif ($n eq 'set-value') { push @{$p->{ops}}, [$n, at($e, 'idref'), val($e)] }
    elsif ($n eq 'refine-value') { push @{$p->{ops}}, [$n, at($e, 'idref'), at($e, 'selector')] }
    elsif ($n eq 'refine-rule') { push @{$p->{ops}}, [$n, at($e, 'idref'), at($e, 'severity'), at($e, 'selector'), at($e, 'weight')] }
  }
  return $p;
}

sub resolve {
  my ($p) = @_;
  my @chain;
  for (my $x = $p; $x;) {
    unshift @chain, $x;
    my $bid = strip_hash($x->{extends});
    my $next;
    if ($bid ne '') { for my $q (@{$D{profiles}}) { if ($q->{id} eq $bid && !grep { $_ == $q } @chain) { $next = $q; last } } }
    $x = $next;
  }
  my %st;
  $st{$_->{id}} = $_->{on} for @{$D{groups}};
  $st{$_->{id}} = $_->{on} for @{$D{rules}};
  $p->{selected} = {}; $p->{refine} = {}; $p->{sets} = {}; $p->{rr} = {};
  for my $o (map { @{$_->{ops}} } @chain) {
    my ($k, $id, $v) = @$o;
    if ($k eq 'select') {
      my $on = is_true($v);
      if (exists $st{$id}) { $st{$id} = $on }
      else { for (@{$D{rules}}, @{$D{groups}}) { $st{$_->{id}} = $on if $_->{cluster} ne '' && $_->{cluster} eq $id } }
    }
    elsif ($k eq 'set-value') { $p->{sets}{$id} = $v }
    elsif ($k eq 'refine-value') { $p->{refine}{$id} = $v; delete $p->{sets}{$id} }
    else { $p->{rr}{$id} = $o }
  }
  RULE: for my $r (@{$D{rules}}) {
    next unless $st{$r->{id}};
    for (my $g = $r->{parent}; $g; $g = $g->{parent}) { next RULE unless $st{$g->{id}} }
    $p->{selected}{$r->{id}} = 1;
  }
  my %g = map { $_->{id} => 1 } @{$D{groups}};
  my $on = sub { return $p->{selected}{$_[0]} || ($g{$_[0]} && $st{$_[0]}) };
  my @drop;
  for my $r (@{$D{rules}}) {
    next unless $p->{selected}{$r->{id}};
    my $bad = 0;
    for my $any (@{$r->{requires}}) { $bad = 1 unless grep { $on->($_) } @$any }
    for (@{$r->{conflicts}}) { $bad = 1 if $on->($_) }
    push @drop, $r->{id} if $bad;
  }
  delete $p->{selected}{$_} for @drop;
}

sub default_profile { my $p = { id => '', title => '', extends => '', ops => [], description => '' }; resolve($p); return $p }

sub find_profile {
  my ($n) = @_;
  return undef unless defined $n;
  for (@{$D{profiles}}) { return $_ if $_->{id} eq $n || lc $_->{title} eq lc $n || $_->{id} =~ /_profile_\Q$n\E$/ }
  die "profile not found: $n (see: scriptix info)\n";
}

sub load_tailoring {
  my ($file) = @_;
  my $root = parse_xml($file);
  die "$file isn't an XCCDF tailoring file\n" unless $root->[0] eq 'Tailoring';
  my $b = el($root, 'benchmark');
  my $t = $b ? at($b, 'id') : '';
  die "this tailoring file belongs to another benchmark ($t)\n" if $t ne '' && $D{id} ne '' && $t ne $D{id};
  my @add = map { read_profile($_, 1) } els($root, 'Profile');
  die "the tailoring file has no profile\n" unless @add;
  for my $p (@add) {
    my $x = strip_hash($p->{extends});
    die "the tailoring extends profile $x, which isn't in this benchmark\n" if $x ne '' && !grep { $_->{id} eq $x } @{$D{profiles}}, @add;
    $D{profiles} = [grep { !($_->{id} eq $p->{id} && ($_->{tailored} || $x ne $p->{id})) } @{$D{profiles}}];
  }
  unshift @{$D{profiles}}, @add;
  resolve($_) for @{$D{profiles}};
}

sub profile_value {
  my ($id, $p) = @_;
  return $p->{sets}{$id} if $p && exists $p->{sets}{$id};
  my $v = $D{values}{$id};
  return $D{plain}{$id} unless $v;
  return $v->{sel}{$p->{refine}{$id}} if $p && exists $p->{refine}{$id} && exists $v->{sel}{$p->{refine}{$id}};
  return $v->{def} if defined $v->{def};
  return @{$v->{selorder}} ? $v->{sel}{$v->{selorder}[0]} : undef;
}
sub value { my ($id, $p) = @_; return exists $D{overrides}{$id} ? $D{overrides}{$id} : profile_value($id, $p) }
sub value_list {
  my ($id, $p) = @_;
  my $v = $D{values}{$id};
  if (!exists $D{overrides}{$id} && $v && %{$v->{lists}}) {
    my $s = $p && exists $p->{refine}{$id} ? $p->{refine}{$id} : '';
    return $v->{lists}{$s} if $v->{lists}{$s};
    return $v->{lists}{''} if $v->{lists}{''};
  }
  my $one = value($id, $p);
  return defined $one ? [$one] : [];
}

sub fix_kind {
  my ($s) = @_;
  for my $k (['script:ansible', 'ansible'], ['script:puppet', 'puppet'], ['kickstart', 'kickstart'], ['kubernetes', 'kubernetes'], ['ignition', 'ignition'],
    ['blueprint', 'blueprint'], ['bootc', 'bootc'], ['powershell', 'powershell']) { return $k->[1] if $s =~ /\Q$k->[0]\E/i }
  return 'bash' if $s =~ /script:sh|bash|system:commands/i || $s eq '';
  return 'other';
}
sub fix_of { my ($r, $kind) = @_; for (@{$r->{fixes}}) { return $_ if fix_kind(at($_, 'system')) eq $kind } return undef }
sub fix_text {
  my ($f, $p) = @_;
  my $s = '';
  for my $n (@{$f->[3]}) {
    if (!ref $n) { $s .= ent($n) }
    elsif ($n->[0] eq 'sub') { my $id = at($n, 'idref'); my $v = value($id, $p); $s .= defined $v ? $v : '<SET ' . short_id($id, '_value_') . '>' }
    elsif ($n->[0] ne 'instance') { $s .= val($n) }
  }
  return trim($s);
}

# ---------------------------------------------------------------- checks
sub first_def { my ($n) = @_; return $n->[0] if defined $n->[0]; for (@{$n->[3]}) { my $d = first_def($_); return $d if defined $d } return undef }

sub oval_node {
  my ($check, $p, $ext) = @_;
  $ext->{at($_, 'export-name')} = value_list(at($_, 'value-id'), $p) for els($check, 'check-export');
  for my $c (els($check, 'check-content-ref')) {
    my $file = find_file(at($c, 'href'));
    my $name = at($c, 'name');
    if ($name ne '') {
      return [$name, 'AND', 0, []] if $OV{$name};
      if ($file) { refresh_oval(); return [$name, 'AND', 0, []] if $OV{$name} }
      next;
    }
    next unless $file && $file->[0] eq 'oval_definitions';
    refresh_oval();
    my @d = grep { $_ ne '' } map { at($_, 'id') } map { kids($_) } grep { $_ } el($file, 'definitions');
    next unless @d;
    return [undef, 'AND', 0, [map { [$_, 'AND', 0, []] } @d]];
  }
  return undef;
}
sub complex_node {
  my ($e, $p, $ext) = @_;
  my @k;
  for my $c (kids($e)) {
    my $k = $c->[0] eq 'complex-check' ? complex_node($c, $p, $ext) : $c->[0] eq 'check' && at($c, 'system') eq $OVALSYS ? oval_node($c, $p, $ext) : undef;
    push @k, $k || [undef, 'AND', 0, []] if $c->[0] eq 'check' || $c->[0] eq 'complex-check';
  }
  return undef unless grep { defined $_->[0] || @{$_->[3]} } @k;
  return [undef, at($e, 'operator') eq 'OR' ? 'OR' : 'AND', is_true(at($e, 'negate')), \@k];
}
sub q_sh { my ($s) = @_; $s =~ s/'/'\\''/g; return "'$s'" }
sub sce_script {
  my ($check, $p) = @_;
  for my $c (els($check, 'check-content-ref')) {
    my $b = find_file(at($c, 'href'));
    next unless $b && $b->[0] eq 'script';
    my $s = "XCCDF_RESULT_PASS=101 XCCDF_RESULT_FAIL=102 XCCDF_RESULT_ERROR=103 XCCDF_RESULT_UNKNOWN=104 XCCDF_RESULT_NOT_APPLICABLE=105 XCCDF_RESULT_NOT_CHECKED=106 XCCDF_RESULT_NOT_SELECTED=107 XCCDF_RESULT_INFORMATIONAL=108 XCCDF_RESULT_FIXED=109\n"
      . "export XCCDF_RESULT_PASS XCCDF_RESULT_FAIL XCCDF_RESULT_ERROR XCCDF_RESULT_UNKNOWN XCCDF_RESULT_NOT_APPLICABLE XCCDF_RESULT_NOT_CHECKED XCCDF_RESULT_NOT_SELECTED XCCDF_RESULT_INFORMATIONAL XCCDF_RESULT_FIXED\n";
    for my $e (els($check, 'check-export')) {
      my $n = at($e, 'export-name'); $n =~ s/[^A-Za-z0-9_]/_/g;
      my $v = value(at($e, 'value-id'), $p); $v = '' unless defined $v;
      $s .= "XCCDF_VALUE_$n=" . q_sh($v) . "; export XCCDF_VALUE_$n\n" if $n ne '';
    }
    return $s . trim(val($b));
  }
  return undef;
}
my %OCIL;
sub question {
  my (@checks) = @_;
  for my $c (@checks) {
    my $x = el($c, 'check-content');
    return cut(text($x), 1000) if $x && trim(val($x)) ne '';
    next unless at($c, 'system') =~ /ocil/i;
    for my $rf (els($c, 'check-content-ref')) {
      find_file(at($rf, 'href'));
      for my $o (@{$S{ocil}}) {
        my $ix = $OCIL{$o} ||= do {
          my %h = (q => {}, a => {}, t => {});
          walk($o, sub {
            my ($n) = @_; my $l = $n->[0];
            my $s = $l eq 'questionnaire' ? 'q' : $l =~ /_test_action$/ ? 'a' : $l =~ /_question$/ ? 't' : return;
            my $id = at($n, 'id'); $h{$s}{$id} = $n unless $h{$s}{$id};
          });
          \%h;
        };
        my $q = $ix->{q}{at($rf, 'name')} or next;
        my $act;
        walk($q, sub { $act = trim(val($_[0])) if !defined $act && $_[0][0] eq 'test_action_ref' });
        my $a = defined $act ? $ix->{a}{$act} : undef;
        my $t = $a ? $ix->{t}{at($a, 'question_ref')} : undef;
        my $qt = $t ? text(el($t, 'question_text')) : '';
        return cut($qt, 1000) if $qt ne '';
      }
    }
  }
  return undef;
}

# ---------------------------------------------------------------- platforms
my (%PCACHE, $PSPEC);
sub platform_for {
  my ($r) = @_;
  my @lv;
  my $add = sub {
    my ($names) = @_;
    return unless @$names;
    my @n = map { platform($_) } @$names;
    return if grep { !$_ } @n;   # unknown platform: don't hide the rule because of it
    push @lv, @n == 1 ? $n[0] : [undef, 'OR', 0, \@n];
  };
  $add->($r->{platforms});
  for (my $g = $r->{parent}; $g; $g = $g->{parent}) { $add->($g->{platforms}) }
  $add->($D{platforms});
  return @lv == 0 ? undef : @lv == 1 ? $lv[0] : [undef, 'AND', 0, \@lv];
}
sub platform { my ($id) = @_; $PCACHE{$id} = [find_platform($id)] unless $PCACHE{$id}; return $PCACHE{$id}[0] }
sub find_platform {
  my ($idref) = @_;
  if ($idref =~ /^#(.*)$/s) {
    my $id = $1;
    unless ($PSPEC) { $PSPEC = {}; walk($S{bench}, sub { my ($n) = @_; return unless $n->[0] eq 'platform'; my $i = at($n, 'id'); $PSPEC->{$i} = $n unless $PSPEC->{$i} }) }
    my $t = $PSPEC->{$id} ? el($PSPEC->{$id}, 'logical-test') : undef;
    return $t ? logical($t) : undef;
  }
  for my $d (@{$S{dicts}}) {
    my @it = els($d, 'cpe-item');
    my ($item) = grep { at($_, 'name') eq $idref } @it;
    ($item) = grep { cpe_match($idref, at($_, 'name')) } @it unless $item;
    my $check = $item ? el($item, 'check') : undef;
    next unless $check;
    my $def = trim(val($check));
    find_file(at($check, 'href')); refresh_oval();
    return [$def, 'AND', 0, []] if $OV{$def};
  }
  return undef;
}
sub logical {
  my ($t) = @_;
  my @k;
  for my $c (kids($t)) {
    my $k;
    if ($c->[0] eq 'logical-test') { $k = logical($c) }
    elsif ($c->[0] eq 'fact-ref') { $k = platform(at($c, 'name')) }
    elsif ($c->[0] eq 'check-fact-ref') { find_file(at($c, 'href')); refresh_oval(); my $i = at($c, 'id-ref'); $k = [$i, 'AND', 0, []] if $OV{$i} }
    else { next }
    return undef unless $k;
    push @k, $k;
  }
  return undef unless @k;
  return [undef, at($t, 'operator') eq 'OR' ? 'OR' : 'AND', is_true(at($t, 'negate')), \@k];
}
sub cpe_match {
  my ($a, $b) = @_;
  return 0 unless $a =~ s{^cpe:/}{} && $b =~ s{^cpe:/}{};
  my @x = split /:/, $a, -1; my @y = split /:/, $b, -1;
  for (my $i = 0; $i < @x && $i < @y; $i++) { return 0 if $x[$i] ne '' && $y[$i] ne '' && $x[$i] ne '-' && $y[$i] ne '-' && lc $x[$i] ne lc $y[$i] }
  return @x >= 3 && @y >= 3;
}

# ---------------------------------------------------------------- OVAL files (CVE feeds, patch advisories)
sub load_oval {
  my ($base) = @_;
  refresh_oval();
  $D{title} = $base; $D{prebuilt} = [];
  for my $id (@OVIDS) {
    my $d = $OV{$id};
    next if $d->[0] ne 'definition' || is_true(at($d, 'deprecated')) || !el($d, 'criteria');
    my $m = el($d, 'metadata');
    my $sev = '';
    if ($m) { my $s; walk($m, sub { $s = $_[0] if !$s && $_[0] != $m && $_[0][0] eq 'severity' }); $sev = lc text($s) }
    my $t = $m ? text(el($m, 'title')) : $id;
    push @{$D{prebuilt}}, { id => $id, title => $t ne '' ? $t : $id, severity => $sev =~ /^(?:critical|important|high)$/ ? 'high' : $sev =~ /^(?:low|negligible)$/ ? 'low' : 'medium' };
  }
  die "this OVAL file has no definitions with criteria\n" unless @{$D{prebuilt}};
}

# ================================================================ script items and the script (the app's ScriptBuilder)
sub severity { my $s = lc trim($_[0]); return $s =~ /^(?:low|info|informational)$/ ? 'low' : $s =~ /^(?:high|critical)$/ ? 'high' : 'medium' }
sub safe_id { my ($id, $n) = @_; $id = trim($id); $id =~ s/[^A-Za-z0-9._:-]/_/g; $id = substr($id, 0, 100) if length $id > 100; return $id eq '' ? sprintf('ITEM-%03d', $n) : $id }
sub wanted { my ($r, $l) = @_; return grep { $_ eq $r->{id} || (defined $r->{short} && $_ eq $r->{short}) } @$l }

sub rule_names {   # the id a rule has in scripts and results
  my %n; $n{$_->{short}}++ for @{$D{rules}};
  return { map { $_->{id} => ($n{$_->{short}} > 1 ? $_->{id} : $_->{short}) } @{$D{rules}} };
}

sub check_items {
  my ($p, $only, $skip) = @_;
  my @it;
  if ($D{prebuilt}) {
    for my $r (@{$D{prebuilt}}) {
      next if (@$only && !wanted($r, $only)) || wanted($r, $skip);
      push @it, { id => $r->{id}, title => $r->{title}, sev => $r->{severity}, os => 'any', mode => 'oval', cmd => "oval $r->{id}", tmo => 900, data => compile_oval([$r->{id}, 'AND', 0, []], undef, {}) };
    }
    return @it;
  }
  my $names = rule_names();
  for my $x (@{$D{rules}}) {
    next unless $p->{selected}{$x->{id}};
    next if (@$only && !wanted($x, $only)) || wanted($x, $skip);
    my $rr = $p->{rr}{$x->{id}};
    my $sel = $rr ? $rr->[3] : '';
    my %i = (id => $names->{$x->{id}}, title => $x->{title}, sev => severity($rr && $rr->[2] ne '' ? $rr->[2] : $x->{severity}), os => $D{target}, tmo => 900, data => '');
    my $plat = platform_for($x);
    my %ext; my $node;
    my ($complex) = grep { $_->[0] eq 'complex-check' } @{$x->{checks}};
    $node = complex_node($complex, $p, \%ext) if $complex;
    my @simple = grep { $_->[0] eq 'check' } @{$x->{checks}};
    if (!$node) {
      my @ov = grep { at($_, 'system') eq $OVALSYS } @simple;
      my ($pick) = grep { at($_, 'selector') eq $sel } @ov;
      ($pick) = grep { at($_, 'selector') eq '' } @ov unless $pick;
      $node = oval_node($pick, $p, \%ext) if $pick;
    }
    if ($node) {
      my $d = first_def($node);
      $i{data} = compile_oval($node, $plat, \%ext);
      $i{mode} = 'oval'; $i{os} = 'any'; $i{cmd} = 'oval ' . (defined $d ? $d : $x->{short});
    }
    else {
      my ($sce) = grep { at($_, 'system') eq 'http://open-scap.org/page/SCE' } @simple;
      my $s = $sce ? sce_script($sce, $p) : undef;
      if (defined $s) { $i{mode} = 'sce'; $i{cmd} = $s; $i{tmo} = 0; $i{bash} = $s =~ /bash/ }
      else {
        my $q = question(@simple);
        $i{mode} = 'manual'; $i{cmd} = defined $q ? $q : 'Check this rule by hand.';
        $i{data} = compile_oval(undef, $plat, {}) if $plat;
      }
    }
    push @it, \%i;
  }
  return @it;
}

# fixes of the failed rules (or of every rule of the profile); those that still need a value are left out
sub fix_items {
  my ($p, $failed) = @_;
  my @it;
  my $names = rule_names();
  for my $x (@{$D{rules}}) {
    next unless $p->{selected}{$x->{id}};
    next if $failed && !$failed->{safe_id($x->{id}, 0)} && !$failed->{safe_id($x->{short}, 0)};
    my $f = fix_of($x, 'bash') or next;
    my $t = fix_text($f, $p);
    next if $t eq '' || $t =~ /<[A-Za-z_][A-Za-z0-9_.:-]*( [A-Za-z0-9_.:-]+)*>|xccdf_value/;
    my $rr = $p->{rr}{$x->{id}};
    push @it, { id => $names->{$x->{id}}, title => $x->{title}, sev => severity($rr && $rr->[2] ne '' ? $rr->[2] : $x->{severity}), os => $D{target}, mode => 'rc0', cmd => $t, tmo => 0, data => '', bash => $D{target} ne 'AIX' };
  }
  return @it;
}

my @RISK = (qr/\brm\s+-[a-zA-Z]*[rR]/, qr/\bmkfs|\bdd\s+if=|\bwipefs\b|\bfdisk\b|\bparted\b/, qr/\bshutdown\b|\breboot\b|\bhalt\b|\binit\s+[06]\b|\bpoweroff\b/,
  qr/\buserdel\b|\busermod\b|\bpasswd\b|\bchpasswd\b|\brmuser\b|\bpwdadm\b/, qr/\biptables\b|\bip6tables\b|\bnft\b|firewall-cmd|\bufw\b|\bgenfilt\b|\bmkfilt\b/,
  qr/sshd_config|PermitRootLogin|\bAllowUsers\b|\bAllowGroups\b/i, qr/pam\.d|\bpam_|faillock|\/etc\/security\/login\.cfg/i, qr/fstab|\bmount\b|remount|\/etc\/filesystems/,
  qr/grub|bootlist|\bbosboot\b/i, qr/\b(chmod|chown|chgrp)\s+-R\s+\//, qr/\b(yum|dnf|zypper)\s+(-y\s+)?(remove|erase)|\bapt(-get)?\s+(-y\s+)?(remove|purge)|\brpm\s+-e|\binstallp\s+-u/,
  qr/systemctl\s+(disable|mask|stop)|\bstopsrc\b|chsubserver\s+-d|\bsvc_disable\b|\bchrctcp\b/, qr/\bcurl\b|\bwget\b|\bftp\b|\bscp\b|\btftp\b/,
  qr/\bchmod\s+(-[a-zA-Z]+\s+)*0?777\b/, qr/\bselinux\b|\bsetenforce\b/i);

sub slurp { my ($f) = @_; open(my $h, '<', $f) or die "cannot read $f: $!\n"; binmode($h); local $/; my $t = <$h>; close($h); $t = '' unless defined $t; utf8::decode($t); $t =~ s/\r\n/\n/g; return $t }
sub spew { my ($f, $t) = @_; open(my $h, '>', $f) or die "cannot write $f: $!\n"; binmode($h); utf8::encode($t) if utf8::is_utf8($t); print $h $t or die "cannot write $f: $!\n"; close($h) or die "cannot write $f: $!\n" }
sub out { my ($f, $t) = @_; if (defined $f && $f ne '-') { spew($f, $t) } else { binmode(STDOUT); utf8::encode($t) if utf8::is_utf8($t); print $t } }

# SHA-256 with the system's own tool, as the scripts do it
sub sha {
  my ($text, $tmp) = @_;
  spew($tmp, $text);
  my $q = q_sh($tmp);
  for my $c ("sha256sum $q", "shasum -a 256 $q", "openssl dgst -sha256 $q", "digest -a sha256 $q", "sha256 -q $q", "csum -h SHA256 $q") {
    my ($tool) = $c =~ /^(\S+)/;
    next unless grep { -x "$_/$tool" } split /:/, $ENV{PATH};
    my $o = `$c 2>/dev/null`;
    if ($o =~ /\b([0-9a-f]{64})\b/) { unlink $tmp; return $1 }
  }
  unlink $tmp;
  die "no SHA-256 tool found (sha256sum, shasum, openssl, digest, csum)\n";
}

sub build_script {
  my ($lib, $outfile, $kind, $readonly, @items) = @_;
  die "a script needs at least one command\n" unless @items;
  my (%seen, $lines, $risky, $n) = ();
  $lines = ''; $risky = 0; $n = 0;
  for my $i (@items) {
    my $id = safe_id($i->{id}, ++$n);
    my $u = $id;
    for (my $k = 2; $seen{$u}++; $k++) { $u = "${id}_$k" }
    $i->{id} = $u;
    $i->{title} =~ s/[\x00-\x1f\x7f]/ /g; $i->{title} = trim($i->{title}); $i->{title} = substr($i->{title}, 0, 200);
    $i->{cmd} =~ s/\r\n/\n/g; $i->{cmd} = trim($i->{cmd});
    die "$i->{id}: contains a NUL character\n" if "$i->{cmd}$i->{title}$i->{data}" =~ /\0/;
    if (!$readonly) { for my $r (@RISK) { if ($i->{cmd} =~ $r) { $risky++; last } } }
    my $h = $i->{cmd} =~ /^\s*(?:setcfg|sysctl_set|fperm|fowner|line_add|line_del|svc_disable|aix_chsec|aix_chuser|aix_no)\s[^;&|<>`\$\n\r\\]*$/ && !$i->{bash};
    my $flags = ($h ? 'h' : '') . ($i->{bash} ? 'b' : '') . ($i->{mode} eq 'oval' ? 'o' : $i->{mode} eq 'sce' ? 's' : $i->{mode} eq 'manual' ? 'm' : '');
    $lines .= join(' ', 'run_item', map { q_sh($_) } $u, $i->{title}, $i->{sev}, $i->{os}, $i->{mode}, '', $i->{tmo}, $flags, $i->{cmd}) . "\n";
  }
  my $body = slurp("$lib/runtime.sh");
  my $count = @items;
  my $ro = $readonly ? '1' : '0';
  my $root = $readonly ? '0' : '1';
  my %v = (KIND => $kind, VERSION => $VERSION, TOTAL => $count, RISKY => $risky, STOP => '0', NEEDROOT => $root, TIMEOUT => '60', REDACT => '1', READONLY => $ro);
  $body =~ s/\{\{(KIND|VERSION|TOTAL|RISKY|STOP|NEEDROOT|TIMEOUT|REDACT|READONLY)\}\}/$v{$1}/g;
  $body .= "\n" unless $body =~ /\n\z/;
  my $oval = '';
  if (grep { $_->{data} ne '' } @items) {
    $oval = "mkdir \"\$WORK/ir\" \"\$WORK/c\" || { err \"Cannot create \$WORK/ir\"; exit 3; }\ncat > \"\$WORK/oval.awk\" <<'SX_END_OF_ENGINE'\n" . slurp("$lib/oval.awk");
    $oval .= "\n" unless $oval =~ /\n\z/;
    $oval .= "SX_END_OF_ENGINE\ncat > \"\$WORK/oval.ir\" <<'SX_END_OF_CHECKS'\n";
    for my $i (grep { $_->{data} ne '' } @items) { my $d = $i->{data}; $d =~ tr/\r//d; $d =~ s/\n+\z//; $oval .= "#ID\t$i->{id}\n$d\n" }
    $oval .= "SX_END_OF_CHECKS\nawk -v D=\"\$WORK/ir\" '/^#ID\\t/ { if (f != \"\") close(f); f = D \"/\" substr(\$0, 5); next } { print > f }' \"\$WORK/oval.ir\"\n";
  }
  my ($a, $b) = split /\{\{ITEMS\}\}\n/, $body, 2;
  my ($c, $d) = split /\{\{OVAL\}\}\n/, $b, 2;
  $body = $a . $lines . $c . $oval . $d;
  my $opt = "ScriptOptions { Kind = $kind, StopOnFail = False, RequireRoot = " . ($readonly ? 'False' : 'True') . ", TimeoutSeconds = 60, Redact = True, ReadOnly = " . ($readonly ? 'True' : 'False') . ' }';
  my $sha = sha($body, "$outfile.tmp");
  my $input = substr(sha($lines . $oval . '|' . $opt, "$outfile.tmp"), 0, 16);
  my $head = "#!/bin/sh\n# ScriptIX $VERSION - $kind script for Linux and AIX (POSIX sh)\n# Commands: $count   Flagged risky: $risky   Input hash: $input\n"
    . "# Help: sh THIS_FILE --help    Preview: --dry-run    Integrity: --verify\n# Do not edit anything below the BODY marker, or --verify will report a change.\n"
    . "# Solaris: use the POSIX shell when /bin/sh is the old Bourne shell.\n"
    . "if [ -z \"\${SX_REEXEC:-}\" ] && [ -x /usr/xpg4/bin/sh ] && [ \"`uname -s`\" = SunOS ]; then\n  SX_REEXEC=1; export SX_REEXEC; exec /usr/xpg4/bin/sh \"\$0\" \"\$@\"\nfi\n"
    . "SX_SHA256='$sha'\n#__SCRIPTIX_BODY__\n";
  spew($outfile, $head . $body);
  return $count;
}

# ================================================================ results
sub read_csv {
  my ($file) = @_;
  my $t = slurp($file);
  $t =~ s/^\x{feff}//; $t =~ s/^#scriptix [^\n]*\n//;
  my (@rows, @f);
  pos($t) = 0;
  while (pos($t) < length $t) {
    my $v;
    if ($t =~ /\G"((?:[^"]|"")*)"/gc) { $v = $1; $v =~ s/""/"/g } else { $t =~ /\G([^,\n]*)/gc; $v = $1 }
    push @f, $v;
    if ($t =~ /\G,/gc) { push @f, '' if pos($t) == length $t; next }
    $t =~ /\G[^\n]*\n?/gc;
    push @rows, [@f]; @f = ();
  }
  push @rows, [@f] if @f;
  my $h = shift @rows or die "the results file is empty\n";
  my %c; for (my $i = 0; $i < @$h; $i++) { $c{lc trim($h->[$i])} = $i }
  die "$file isn't a ScriptIX results file\n" unless defined $c{seq} && defined $c{result};
  my @out;
  for my $r (@rows) {
    next unless grep { /\S/ } @$r;
    my %o;
    for my $n (keys %c) { my $v = defined $r->[$c{$n}] ? $r->[$c{$n}] : ''; $v =~ s/^'(?=[=+\@-])//; $o{$n} = $v }
    for (qw(id title severity time detail rc seconds command expected output mode os)) { $o{$_} = '' unless defined $o{$_} }
    $o{result} = uc trim($o{result});
    push @out, \%o;
  }
  return \@out;
}

sub from_xccdf { my ($x) = @_; my %m = (pass => ['PASS', ''], fixed => ['PASS', 'FIXED'], fail => ['FAIL', ''], error => ['SKIPPED', 'ERROR'], unknown => ['SKIPPED', 'UNKNOWN'],
  notapplicable => ['SKIPPED', 'NOT-APPLICABLE'], informational => ['SKIPPED', 'INFORMATIONAL'], notselected => ['SKIPPED', 'FILTERED']); return @{$m{$x} || ['SKIPPED', 'NOT-CHECKED']} }
# XCCDF results or ARF, as oscap writes them
my $RESPROF;
sub read_xml_results {
  my ($file) = @_;
  my $root = parse_xml($file);
  my ($tr, %rules);
  walk($root, sub { my ($n) = @_; if ($n->[0] eq 'TestResult') { $tr = $n } elsif ($n->[0] eq 'Rule') { $rules{at($n, 'id')} = $n unless $rules{at($n, 'id')} } });
  die "$file holds no XCCDF results\n" unless $tr;
  my $pr = el($tr, 'profile'); $RESPROF = $pr ? at($pr, 'idref') : undef;
  my @rows;
  for my $rr (els($tr, 'rule-result')) {
    my $res = text(el($rr, 'result'));
    next if $res eq 'notselected';
    my $id = at($rr, 'idref'); my $rule = $rules{$id};
    my ($r, $d) = from_xccdf($res);
    my $check = '';
    walk($rr, sub { $check = at($_[0], 'name') if $check eq '' && $_[0][0] eq 'check-content-ref' });
    push @rows, { seq => @rows + 1, id => short_id($id, '_rule_'), title => $rule ? text(el($rule, 'title')) : '', severity => at($rr, 'severity') ne '' ? at($rr, 'severity') : $rule ? at($rule, 'severity') : '',
      time => '', result => $r, detail => $d, rc => '', seconds => '', command => $check ne '' ? "oval $check" : '', expected => '', output => join("\n", map { trim(val($_)) } els($rr, 'message')), mode => '', os => '' };
  }
  die "$file holds no rule results\n" unless @rows;
  my $when = at($tr, 'start-time') ne '' ? at($tr, 'start-time') : at($tr, 'end-time');
  $when = substr($when, 0, 19); $when =~ s/T/ /;
  return (\@rows, text(el($tr, 'target')), $when);
}
sub load_rows { my ($f) = @_; return $f =~ /\.xml$/i ? (read_xml_results($f)) : (read_csv($f), describe($f)) }
sub describe { my ($f) = @_; return $f =~ m{(?:^|/)results_([^/]+)_(\d{4})(\d\d)(\d\d)_(\d\d)(\d\d)(\d\d)\.csv$} ? ($1, "$2-$3-$4 $5:$6:$7") : ('', '') }

sub to_xccdf {
  my ($r) = @_; my $d = $r->{detail};
  return $d eq 'FIXED' ? 'fixed' : 'pass' if $r->{result} eq 'PASS';
  return $d eq 'TIMEOUT' || $d eq 'INTERRUPTED' ? 'error' : 'fail' if $r->{result} eq 'FAIL';
  return $d eq 'NOT-APPLICABLE' || $d eq 'OTHER-OS' ? 'notapplicable' : $d eq 'FILTERED' ? 'notselected' : $d =~ /^(?:ERROR|TIMEOUT|PREVIEW-FAILED)$/ ? 'error'
    : $d eq 'UNKNOWN' ? 'unknown' : $d eq 'INFORMATIONAL' || $d eq 'WAIVED' ? 'informational' : 'notchecked';
}

# [row, rule] pairs; rule is undef without content
sub match_rows {
  my ($rows) = @_;
  my (%f, %s);
  for my $r (@{$D{rules} || []}) { my $a = safe_id($r->{id}, 0); $f{$a} = $r unless $f{$a}; my $b = safe_id($r->{short}, 0); $s{$b} = $r unless $s{$b} }
  return map { [$_, $f{$_->{id}} || $s{$_->{id}}] } @$rows;
}

sub scores {
  my ($rows, $p) = @_;
  my @l = grep { $_->[2] =~ /^(?:pass|fixed|fail|error|unknown)$/ } map { [$_->[0], $_->[1], to_xccdf($_->[0])] } match_rows($rows);
  my $w = sub { my ($r) = @_; return 1 unless $r; my $o = $p ? $p->{rr}{$r->{id}} : undef; return $o && defined $o->[4] && $o->[4] =~ /^\s*[-+]?(?:\d+\.?\d*|\.\d+)\s*$/ ? $o->[4] + 0 : $r->{weight} };
  my $ok = sub { return $_[0] eq 'pass' || $_[0] eq 'fixed' };
  my ($flat, $max, $n) = (0, 0, 0);
  for (@l) { my $x = $w->($_->[1]); $max += $x; if ($ok->($_->[2])) { $flat += $x; $n++ } }
  my $def;
  if (!grep { $_->[1] } @l) { $def = $max > 0 ? $flat / $max * 100 : 0 }
  else {
    my %by; for (@l) { $by{$_->[1]{id}} = $_->[2] if $_->[1] && !defined $by{$_->[1]{id}} }
    my (%kg, %kr);
    push @{$kg{$_->{parent} || ''}}, $_ for @{$D{groups}};
    push @{$kr{$_->{parent} || ''}}, $_ for @{$D{rules}};
    my $item;
    $item = sub {
      my ($key) = @_;
      my ($sum, $acc, $any) = (0, 0, 0);
      for my $r (@{$kr{$key} || []}) { my $res = $by{$r->{id}}; next unless defined $res; $any = 1; $sum += ($ok->($res) ? 100 : 0) * $w->($r); $acc += $w->($r) }
      for my $g (@{$kg{$key} || []}) { my ($s, $has) = $item->($g); next unless $has; $any = 1; $sum += $s * $g->{weight}; $acc += $g->{weight} }
      return ($acc > 0 ? $sum / $acc : 0, $any);
    };
    ($def) = $item->('');
  }
  return (['urn:xccdf:scoring:default', sprintf('%.6f', $def), 100], ['urn:xccdf:scoring:flat', $flat, $max], ['urn:xccdf:scoring:flat-unweighted', $n, scalar @l],
    ['urn:xccdf:scoring:absolute', @l && $n == @l ? 1 : 0, 1]);
}

sub xe { my ($s) = @_; $s = '' unless defined $s; $s =~ s/[^\t\n\x20-\x{d7ff}\x{e000}-\x{fffd}\x{10000}-\x{10ffff}]//g; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; return $s }
sub xa { my $s = xe($_[0]); $s =~ s/"/&quot;/g; $s =~ s/\n/&#10;/g; $s =~ s/\t/&#9;/g; return $s }
sub ncname { my ($s) = @_; $s =~ s/[^A-Za-z0-9._-]/_/g; return $s }
sub now_iso { my @t = localtime; return sprintf('%04d-%02d-%02dT%02d:%02d:%02d', $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0]) }
sub sev4 { my ($s) = @_; return $s =~ /^(?:info|low|medium|high)$/ ? $s : 'unknown' }

# seconds added to YYYY-MM-DDThh:mm:ss
sub add_secs {
  my ($t, $s) = @_;
  $t =~ /^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)$/ or return $t;
  my ($y, $m, $d, $x) = ($1, $2, $3, $4 * 3600 + $5 * 60 + $6 + int($s));
  while ($x >= 86400) {
    $x -= 86400; $d++;
    my @md = (31, $y % 4 == 0 && ($y % 100 || $y % 400 == 0) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
    if ($d > $md[$m - 1]) { $d = 1; $m++; if ($m > 12) { $m = 1; $y++ } }
  }
  return sprintf('%04d-%02d-%02dT%02d:%02d:%02d', $y, $m, $d, int($x / 3600), int($x / 60) % 60, $x % 60);
}

sub test_result {
  my ($rows, $p, $host, $when) = @_;
  my $has = defined $D{id};
  my $start = $when =~ /^(\S+) (\S+)$/ ? "$1T$2" : now_iso();
  my $secs = 0; for (@$rows) { $secs += $_->{seconds} if $_->{seconds} =~ /^\d+(?:\.\d+)?$/ }
  my $end = add_secs($start, $secs);
  my $hid = $host ne '' ? "${host}_" : ''; my $st = $start; $st =~ s/\D//g;
  my $h = $host ne '' ? $host : 'unknown';
  my $x = "<TestResult xmlns=\"$NS12\" id=\"" . xa('xccdf_org.scriptix.content_testresult_' . ncname($hid . $st)) . "\" start-time=\"$start\" end-time=\"$end\" version=\""
    . xa($has && $D{version} ne '' ? $D{version} : '1') . "\" test-system=\"cpe:/a:scriptix:scriptix:$VERSION\">\n";
  $x .= '<benchmark href="' . xa($D{file}) . '" id="' . xa($D{id}) . "\"/>\n" if $has && $D{id} ne '';
  $x .= "<title>ScriptIX scan result</title>\n";
  $x .= '<profile idref="' . xa($p->{id}) . "\"/>\n" if $p && $p->{id} ne '';
  $x .= '<target>' . xe($h) . "</target>\n<target-facts>\n<fact name=\"urn:xccdf:fact:scanner:name\" type=\"string\">ScriptIX</fact>\n<fact name=\"urn:xccdf:fact:scanner:version\" type=\"string\">$VERSION</fact>\n"
    . '<fact name="urn:xccdf:fact:asset:identifier:host_name" type="string">' . xe($h) . "</fact>\n</target-facts>\n";
  if ($has) {
    $x .= '<platform idref="' . xa($_) . "\"/>\n" for @{$D{platforms}};
    for my $id (@{$D{valueorder}}) { my $v = value($id, $p); $x .= '<set-value idref="' . xa($id) . '">' . xe($v) . "</set-value>\n" if defined $v }
  }
  my %done;
  for my $m (match_rows($rows)) {
    my ($row, $rule) = @$m;
    my $id = $rule ? $rule->{id} : $row->{id} =~ /^xccdf_[^_]+_rule_.+$/ ? $row->{id} : 'xccdf_org.scriptix.content_rule_' . ncname($row->{id});
    next if $done{$id}++;
    my $res = to_xccdf($row);
    my $sev = $rule && $rule->{severity} ne '' ? $rule->{severity} : lc $row->{severity};
    $x .= '<rule-result idref="' . xa($id) . '"' . ($rule && $rule->{role} ne '' ? ' role="' . xa($rule->{role}) . '"' : '') . " time=\"$start\" severity=\"" . sev4($sev) . '" weight="'
      . sprintf('%.6f', $rule ? $rule->{weight} : 1) . "\">\n<result>$res</result>\n";
    if ($rule) { $x .= '<ident system="' . xa(at($_, 'system')) . '">' . xe(text($_)) . "</ident>\n" for @{$rule->{idents}} }
    $x .= '<message severity="info">' . xe($row->{output}) . "</message>\n" if $row->{output} ne '' && $res =~ /^(?:fail|error|unknown)$/;
    my ($chk) = $rule ? grep { $_->[0] eq 'check' } @{$rule->{checks}} : ();
    my $rf = $chk ? el($chk, 'check-content-ref') : undef;
    if ($rf) { $x .= '<check system="' . xa(at($chk, 'system')) . '"><check-content-ref' . (at($rf, 'name') ne '' ? ' name="' . xa(at($rf, 'name')) . '"' : '') . ' href="' . xa(at($rf, 'href')) . "\"/></check>\n" }
    elsif ($row->{command} =~ /^oval (oval:\S+)/) { $x .= "<check system=\"$OVALSYS\"><check-content-ref name=\"" . xa($1) . "\" href=\"#oval\"/></check>\n" }
    $x .= "</rule-result>\n";
  }
  if ($has) {
    for my $r (grep { !$done{$_->{id}} } @{$D{rules}}) {
      $x .= '<rule-result idref="' . xa($r->{id}) . "\" time=\"$start\" severity=\"" . sev4($r->{severity}) . '" weight="' . sprintf('%.6f', $r->{weight}) . "\"><result>notselected</result></rule-result>\n";
    }
  }
  $x .= "<score system=\"$_->[0]\" maximum=\"" . sprintf('%.6f', $_->[2]) . '">' . sprintf('%.6f', $_->[1]) . "</score>\n" for scores($rows, $p);
  return $x . "</TestResult>\n";
}

my $XMLHEAD = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";
# the benchmark as text, without old results and signatures, with a tailored profile added
sub bench_copy {
  my ($p) = @_;
  my $b = $S{bench};
  return undef unless $b && $b->[1] eq $NS12;
  my $s = raw_node($b);
  for my $n (reverse grep { $_->[0] eq 'TestResult' || $_->[0] eq 'signature' } kids($b)) {
    my $t = substr(${$FILES{$n->[9]}}, $n->[4], $n->[5] - $n->[4]); utf8::decode($t);
    my $i = rindex($s, $t);
    substr($s, $i, length $t) = '' if $i >= 0;
  }
  if ($p && $p->{tailored}) {
    my ($last) = reverse els($b, 'Profile');
    if ($last) {
      my $t = substr(${$FILES{$last->[9]}}, $last->[4], $last->[5] - $last->[4]); utf8::decode($t);
      my $x = "\n<Profile xmlns=\"$NS12\" id=\"" . xa($p->{id}) . '"' . ($p->{extends} ne '' ? ' extends="' . xa(strip_hash($p->{extends})) . '"' : '') . '><title>' . xe($p->{title}) . "</title>\n";
      for my $o (@{$p->{ops}}) {
        if ($o->[0] eq 'select') { $x .= '<select idref="' . xa($o->[1]) . '" selected="' . xa($o->[2]) . "\"/>\n" }
        elsif ($o->[0] eq 'set-value') { $x .= '<set-value idref="' . xa($o->[1]) . '">' . xe($o->[2]) . "</set-value>\n" }
        elsif ($o->[0] eq 'refine-value') { $x .= '<refine-value idref="' . xa($o->[1]) . '" selector="' . xa($o->[2]) . "\"/>\n" }
      }
      my $i = index($s, $t);
      substr($s, $i + length $t, 0) = "$x</Profile>\n" if $i >= 0;
    }
  }
  return $s;
}
sub xccdf_text {
  my ($rows, $p, $host, $when) = @_;
  my $tr = test_result($rows, $p, $host, $when);
  my $b = bench_copy($p);
  return $XMLHEAD . $tr unless defined $b;
  $b =~ s/(<\/[^<>]+>)\s*\z/$tr$1/;
  return "$XMLHEAD$b\n";
}
sub arf_text {
  my ($rows, $p, $host, $when) = @_;
  my $tr = test_result($rows, $p, $host, $when);
  my $h = $host; $h =~ s/[^A-Za-z0-9.-]/-/g; $h =~ s/^[-.]+//; $h =~ s/[-.]+$//; $h = 'unknown' if $h eq '';
  my $c = $S{root} && $S{root}[0] eq 'data-stream-collection' ? raw_node($S{root}) : bench_copy($p);
  $c = "<Benchmark xmlns=\"$NS12\" id=\"xccdf_org.scriptix.content_benchmark_none\"><status>incomplete</status><title>Own checks</title><version>1</version></Benchmark>" unless defined $c;
  return $XMLHEAD . '<arf:asset-report-collection xmlns:arf="http://scap.nist.gov/schema/asset-reporting-format/1.1" xmlns:core="http://scap.nist.gov/schema/reporting-core/1.1" xmlns:ai="http://scap.nist.gov/schema/asset-identification/1.1">'
    . '<core:relationships xmlns:arfvocab="http://scap.nist.gov/specifications/arf/vocabulary/relationships/1.0#"><core:relationship type="arfvocab:createdFor" subject="xccdf1"><core:ref>collection1</core:ref></core:relationship>'
    . '<core:relationship type="arfvocab:isAbout" subject="xccdf1"><core:ref>asset0</core:ref></core:relationship></core:relationships>'
    . "<arf:report-requests><arf:report-request id=\"collection1\"><arf:content>$c</arf:content></arf:report-request></arf:report-requests>"
    . "<arf:assets><arf:asset id=\"asset0\"><ai:computing-device><ai:fqdn>$h</ai:fqdn><ai:hostname>$h</ai:hostname></ai:computing-device></arf:asset></arf:assets>"
    . "<arf:reports><arf:report id=\"xccdf1\"><arf:content>$tr</arf:content></arf:report></arf:reports></arf:asset-report-collection>\n";
}

# ================================================================ HTML
sub he { my ($s) = @_; $s = '' unless defined $s; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g; $s =~ s/'/&#39;/g; $s =~ s/([\x{a0}-\x{ff}])/'&#' . ord($1) . ';'/ge; return $s }
sub now_text { my $t = now_iso(); $t =~ s/T/ /; return substr($t, 0, 16) }

sub html_report {
  my ($rows, $p, $host, $when, $source) = @_;
  my %n = (PASS => 0, FAIL => 0, SKIPPED => 0);
  $n{$_->{result} eq 'PASS' || $_->{result} eq 'FAIL' ? $_->{result} : 'SKIPPED'}++ for @$rows;
  my $rate = $n{PASS} + $n{FAIL} ? int(100 * $n{PASS} / ($n{PASS} + $n{FAIL})) : 0;
  my ($def) = scores($rows, $p);
  my $score = sprintf('%.1f', $def->[1]);
  my $title = defined $D{title} && $D{title} ne '' ? $D{title} : 'ScriptIX report';
  my $o = <<'EOF';
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root{--bg:#f6f7fb;--card:#fff;--text:#0f172a;--muted:#64748b;--line:#e2e8f0;--pass:#15803d;--passbg:#dcfce7;--fail:#b91c1c;--failbg:#fee2e2;--skip:#475569;--skipbg:#f1f5f9;--accent:#4f46e5}
@media screen and (prefers-color-scheme:dark){:root{--bg:#0b1020;--card:#131a2e;--text:#e2e8f0;--muted:#94a3b8;--line:#243049;--passbg:#0f2e1c;--pass:#4ade80;--failbg:#3a1414;--fail:#f87171;--skipbg:#1e293b;--skip:#cbd5e1;--accent:#a5b4fc}}
*{box-sizing:border-box}body{margin:0;font:14px/1.5 "Segoe UI",system-ui,sans-serif;background:var(--bg);color:var(--text)}
.wrap{max-width:1200px;margin:0 auto;padding:28px 16px}h1{margin:0;font-size:24px}.sub{color:var(--muted);margin:4px 0 22px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:22px}
.tile{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px}
.tile .n{font-size:28px;font-weight:700}.tile .l{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.06em}
.bar{height:10px;border-radius:6px;background:var(--failbg);overflow:hidden;margin-top:8px}.bar i{display:block;height:100%;background:var(--pass)}
table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:12px;overflow:hidden}
th,td{padding:8px 10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
th{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.05em}
code,pre{font:12px/1.45 "Cascadia Mono",Consolas,monospace;white-space:pre-wrap;overflow-wrap:anywhere;margin:0}
.b{display:inline-block;padding:2px 8px;border-radius:999px;font-weight:700;font-size:12px;white-space:nowrap}
.PASS{background:var(--passbg);color:var(--pass)}.FAIL{background:var(--failbg);color:var(--fail)}.SKIPPED{background:var(--skipbg);color:var(--skip)}
.muted{color:var(--muted);overflow-wrap:anywhere}.foot{color:var(--muted);font-size:12px;margin-top:18px}
details{margin-top:6px}summary{cursor:pointer;color:var(--accent);font-weight:600}details p{margin:6px 0}details pre{background:var(--skipbg);border-radius:8px;padding:10px}
@page{size:A4 landscape;margin:12mm}
@media print{*{print-color-adjust:exact;-webkit-print-color-adjust:exact}body{background:#fff;font-size:12px}.wrap{max-width:none;padding:0}tr{break-inside:avoid}}
</style>
EOF
  $o .= '<title>' . he($title) . '</title></head><body><div class="wrap"><h1>' . he($title) . '</h1><p class="sub">';
  $o .= 'Profile <strong>' . he($p->{title}) . '</strong> &middot; ' if $p && $p->{title} ne '';
  $o .= 'Host <strong>' . he($host) . '</strong> &middot; ' if $host ne '';
  $o .= 'run ' . he($when) . ' &middot; ' if $when ne '';
  $o .= 'source ' . he($source) . '</p><div class="tiles">';
  $o .= "<div class=\"tile\"><div class=\"n\">$_->[1]</div><div class=\"l\">$_->[0]</div></div>" for (['Total', scalar @$rows], ["Passed \x{2713}", $n{PASS}], ["Failed \x{2715}", $n{FAIL}], ['Skipped', $n{SKIPPED}]);
  $o .= "<div class=\"tile\"><div class=\"n\">$rate%</div><div class=\"l\">Pass rate</div><div class=\"bar\"><i style=\"width:$rate%\"></i></div></div>";
  $o .= "<div class=\"tile\"><div class=\"n\">$score</div><div class=\"l\">Score of 100</div></div></div>";
  $o .= '<table><thead><tr><th>#</th><th>Result</th><th>Severity</th><th>Rule</th><th>Output</th></tr></thead><tbody>';
  for my $m (match_rows($rows)) {
    my ($r, $x) = @$m;
    my $cls = $r->{result} eq 'PASS' || $r->{result} eq 'FAIL' ? $r->{result} : 'SKIPPED';
    my $lab = $cls eq 'PASS' ? "\x{2713} PASS" : $cls eq 'FAIL' ? "\x{2715} FAIL" : "\x{2013} $r->{result}";
    $o .= '<tr><td>' . he($r->{seq}) . "</td><td><span class=\"b $cls\">" . he($lab) . '</span>' . ($r->{detail} ne '' ? '<div class="muted">' . he($r->{detail}) . '</div>' : '') . '</td><td>' . he($r->{severity})
      . '</td><td><strong>' . he($r->{title} ne '' ? $r->{title} : $r->{id}) . '</strong><div class="muted">' . he($r->{id}) . '</div>';
    if ($x) {
      my ($d, $w) = (cut(text(el($x->{node}, 'description')), 1500), cut(text(el($x->{node}, 'rationale')), 1500));
      my $f = fix_of($x, 'bash');
      $o .= '<details><summary>Details</summary>' . ($d ne '' ? '<p>' . he($d) . '</p>' : '') . ($w ne '' ? '<p><strong>Why:</strong> ' . he($w) . '</p>' : '')
        . (@{$x->{idents}} ? '<p class="muted">' . he(join(', ', map { text($_) } @{$x->{idents}})) . '</p>' : '')
        . ($f && $cls eq 'FAIL' ? '<p><strong>Fix:</strong></p><pre>' . he(fix_text($f, $p)) . '</pre>' : '') . '</details>';
    }
    elsif ($r->{command} ne '') { $o .= '<details><summary>Command</summary><pre>' . he($r->{command}) . '</pre>' . ($r->{expected} ne '' ? '<p class="muted">expected: ' . he($r->{expected}) . '</p>' : '') . '</details>' }
    $o .= '</td><td><pre>' . he($r->{output}) . "</pre></td></tr>\n";
  }
  return $o . "</tbody></table><p class=\"foot\">Made by ScriptIX $VERSION on " . now_text() . ". Output is cut to the first 200 characters; the full log is in run_*.txt next to the results.</p></div></body></html>\n";
}

sub guide {
  my ($p, $sel) = @_;
  my $o = <<'EOF';
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root{--bg:#f6f7fb;--card:#fff;--text:#0f172a;--muted:#64748b;--line:#e2e8f0;--accent:#4f46e5;--hi:#b91c1c;--me:#b45309;--lo:#15803d;--code:#f1f5f9}
@media screen and (prefers-color-scheme:dark){:root{--bg:#0b1020;--card:#131a2e;--text:#e2e8f0;--muted:#94a3b8;--line:#243049;--accent:#a5b4fc;--hi:#f87171;--me:#fbbf24;--lo:#4ade80;--code:#0f172a}}
*{box-sizing:border-box}body{margin:0;font:14px/1.55 "Segoe UI",system-ui,sans-serif;background:var(--bg);color:var(--text)}
.wrap{max-width:1000px;margin:0 auto;padding:28px 16px}h1{margin:0 0 4px;font-size:24px}.sub{color:var(--muted);margin:0 0 20px}
h2{font-size:17px;margin:26px 0 8px;color:var(--accent)}
.rule{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin:0 0 12px;break-inside:avoid-page}
.rule h3{margin:0 0 6px;font-size:15px}.id{color:var(--muted);font:12px Consolas,monospace;overflow-wrap:anywhere}
.sev{font-size:12px;font-weight:700;margin-left:8px}.high{color:var(--hi)}.medium{color:var(--me)}.low{color:var(--lo)}
p{margin:6px 0}pre{background:var(--code);border-radius:8px;padding:10px;white-space:pre-wrap;overflow-wrap:anywhere;font:12px/1.45 Consolas,monospace;margin:8px 0 0}
details{margin-top:8px}summary{cursor:pointer;color:var(--accent);font-weight:600}.toc{columns:2;margin:0 0 20px;padding-left:18px}.toc a{color:var(--accent);text-decoration:none}
.foot{color:var(--muted);font-size:12px;margin-top:18px}
</style>
EOF
  chomp $o;
  my @r = grep { $sel->{$_->{id}} } @{$D{rules}};
  $o .= '<title>' . he($D{title}) . '</title></head><body><div class="wrap"><h1>' . he($D{title}) . '</h1><p class="sub">' . ($p->{title} ne '' ? 'Profile <strong>' . he($p->{title}) . '</strong> &middot; ' : '')
    . @r . ' rules' . ($D{version} ne '' ? ' &middot; version ' . he($D{version}) : '') . '</p>';
  if ($p->{description} ne '') { $o .= '<p>' . he($p->{description}) . '</p>' } elsif ($D{description} ne '') { $o .= '<p>' . he($D{description}) . '</p>' }
  my (@g, %g);
  for (@r) { my $k = $_->{parent} || ''; push @g, $k unless $g{$k}; push @{$g{$k}}, $_ }
  my $name = sub { my ($x) = @_; my @n; for (; $x && @n < 3; $x = $x->{parent}) { unshift @n, $x->{title} if $x->{title} ne '' } return @n ? join(" \x{203a} ", @n) : 'Rules' };
  $o .= '<ul class="toc">';
  for (my $i = 0; $i < @g; $i++) { $o .= "<li><a href=\"#g$i\">" . he($name->($g[$i])) . '</a> (' . @{$g{$g[$i]}} . ')</li>' }
  $o .= '</ul>';
  for (my $i = 0; $i < @g; $i++) {
    $o .= "<h2 id=\"g$i\">" . he($name->($g[$i])) . '</h2>';
    for my $r (@{$g{$g[$i]}}) {
      my $sev = he(lc $r->{severity});
      my ($d, $w) = (cut(text(el($r->{node}, 'description')), 1500), cut(text(el($r->{node}, 'rationale')), 1500));
      $o .= '<div class="rule"><h3>' . he($r->{title}) . "<span class=\"sev $sev\">$sev</span></h3><div class=\"id\">" . he($r->{id}) . '</div>';
      $o .= '<p>' . he($d) . '</p>' if $d ne '';
      $o .= '<p><strong>Why:</strong> ' . he($w) . '</p>' if $w ne '';
      $o .= '<p class="id">' . he(join(', ', map { text($_) } @{$r->{idents}})) . '</p>' if @{$r->{idents}};
      $o .= '<details><summary>Fix (' . he(fix_kind(at($_, 'system'))) . ')</summary><pre>' . he(fix_text($_, $p)) . '</pre></details>' for @{$r->{fixes}};
      $o .= '</div>';
    }
  }
  return $o . "<p class=\"foot\">Made by ScriptIX $VERSION on " . now_text() . '.</p></div></body></html>';
}

# ================================================================ info, fix, tailor, validate
sub info {
  platform_for($_) for @{$D{rules}};   # loads the platform checks, so they are counted too
  refresh_oval();
  my $o = "$S{kind}" . ($S{version} ne '' ? " $S{version}" : '') . ": $D{file}\n\n";
  $o .= "Title: $D{title}\n" if $D{title} ne '';
  $o .= "Id: $D{id}\n" if $D{id} ne '';
  $o .= "Version: $D{version}\n" if $D{version} ne '';
  $o .= "Status: $D{status}\n" if $D{status} ne '';
  $o .= 'Platform: ' . join(', ', @{$D{platforms}}) . "\n" if @{$D{platforms}};
  $o .= 'Benchmarks: ' . join(', ', @{$S{benchmarks}}) . "\n" if @{$S{benchmarks}} > 1;
  $o .= 'Rules: ' . @{$D{rules}} . ' in ' . @{$D{groups}} . ' groups, ' . @{$D{valueorder}} . " values\n" if @{$D{rules}};
  my $count = sub { my (%n, @k); for (@_) { push @k, $_ unless $n{$_}++ } my $i = 0; my %o = map { $_ => $i++ } @k; return join(', ', map { "$_ $n{$_}" } sort { $n{$b} <=> $n{$a} || $o{$a} <=> $o{$b} } @k) };
  $o .= "OVAL definitions: $OVDEFS\nOVAL tests: " . $count->(map { substr($_->[0], 0, -5) } grep { $_->[0] =~ /_test$/ } map { $OV{$_} } @OVIDS) . "\n";
  my @fk; for my $r (@{$D{rules}}) { my %s; push @fk, grep { !$s{$_}++ } map { fix_kind(at($_, 'system')) } @{$r->{fixes}} }
  $o .= 'Fixes: ' . $count->(@fk) . "\n" if @fk;
  if (@{$D{profiles}}) { $o .= "\nProfiles:\n"; $o .= "  $_->{title}  (" . scalar(keys %{$_->{selected}}) . " rules)\n    $_->{id}\n" for @{$D{profiles}} }
  return $o;
}

sub one_line { my ($s) = @_; $s =~ s/[\r\n]+/ /g; return $s }
sub fixes {
  my ($p, $kind, $sel) = @_;
  my @l = grep { $_->[1] } map { [$_, fix_of($_, $kind)] } grep { $sel->{$_->{id}} } @{$D{rules}};
  die "none of these rules has a $kind fix\n" unless @l;
  my $o = $kind eq 'bash' ? "#!/usr/bin/env bash\n" : $kind eq 'ansible' ? "---\n" : '';
  $o .= '# ' . one_line($D{title}) . "\n# Profile: " . one_line($p->{title} ne '' ? $p->{title} : '(none)') . "\n# " . @l . " fixes, made by ScriptIX $VERSION. Test on a spare server first.\n\n";
  if ($kind eq 'ansible') {
    $o .= "- hosts: all\n  tasks:\n";
    for (@l) {
      $o .= "\n    # " . one_line($_->[0]{title}) . "  ($_->[0]{id})\n";
      for my $x (split /\n/, fix_text($_->[1], $p), -1) { if ($x =~ /\S/) { $x =~ s/\s+$//; $o .= "    $x\n" } else { $o .= "\n" } }
    }
    return $o;
  }
  my $n = 0;
  for (@l) {
    my $id = $_->[0]{id}; $n++;
    $o .= "\n" . '#' x 79 . "\n# $n/" . @l . '  ' . one_line($_->[0]{title}) . "\n# $id\n";
    if ($kind eq 'bash') { $id =~ s/[^A-Za-z0-9._-]/_/g; $o .= "(>&2 echo \"$n/" . @l . ": $id\")\n" }
    my $t = fix_text($_->[1], $p); $t =~ tr/\r//d;
    $o .= "$t\n";
  }
  return $o;
}

sub find_rule { my ($n) = @_; for (@{$D{rules}}) { return $_ if $_->{id} eq $n } for (@{$D{rules}}) { return $_ if $_->{short} eq $n } die "rule not found: $n\n" }
sub tailor {
  my ($p, $o) = @_;
  my $sel = { %{($p || default_profile())->{selected}} };
  $sel->{find_rule($_)->{id}} = 1 for map { split /,/ } @{$o->{select} || []};
  delete $sel->{find_rule($_)->{id}} for map { split /,/ } @{$o->{unselect} || []};
  my $start = $p;
  while ($start && $start->{tailored}) { my $x = strip_hash($start->{extends}); my $s = $start; ($start) = grep { $_->{id} eq $x && $_ != $s && !$_->{tailored} } @{$D{profiles}} }
  my $work = { id => 'work', extends => $start ? $start->{id} : '', ops => [], title => '', description => '' };
  resolve($work);
  my %gs;
  for my $r (grep { $sel->{$_->{id}} && !$work->{selected}{$_->{id}} } @{$D{rules}}) { for (my $g = $r->{parent}; $g; $g = $g->{parent}) { push @{$work->{ops}}, ['select', $g->{id}, 'true'] unless $gs{$g->{id}}++ } }
  resolve($work);
  for my $r (@{$D{rules}}) { my $want = $sel->{$r->{id}} ? 1 : 0; push @{$work->{ops}}, ['select', $r->{id}, $want ? 'true' : 'false'] if ($work->{selected}{$r->{id}} ? 1 : 0) != $want }
  my $title = defined $o->{title} ? trim($o->{title}) : $p ? "$p->{title} (tailored)" : 'Custom profile';
  my $name = lc $title; $name =~ s/[^a-z0-9.-]+/-/g; $name =~ s/^-+//; $name =~ s/-+$//; $name = 'custom' if $name eq '';
  my $x = "$XMLHEAD<xccdf:Tailoring xmlns:xccdf=\"$NS12\" id=\"xccdf_org.scriptix.content_tailoring_$name\">\n  <xccdf:benchmark href=\"" . xa($D{file}) . "\"/>\n  <xccdf:version time=\"" . now_iso() . "\">1</xccdf:version>\n"
    . "  <xccdf:Profile id=\"xccdf_org.scriptix.content_profile_$name\"" . ($start ? ' extends="' . xa($start->{id}) . '"' : '') . ">\n    <xccdf:title xml:lang=\"en-US\" override=\"true\">" . xe($title)
    . "</xccdf:title>\n    <xccdf:description xml:lang=\"en-US\" override=\"true\">Made with ScriptIX $VERSION.</xccdf:description>\n";
  $x .= '    <xccdf:select idref="' . xa($_->[1]) . "\" selected=\"$_->[2]\"/>\n" for @{$work->{ops}};
  for my $id (@{$D{valueorder}}) {
    my ($w, $s) = (value($id, $p), profile_value($id, $start));
    next if !defined $w || (defined $s && $w eq $s);
    my $v = $D{values}{$id};
    my ($k) = grep { $v->{sel}{$_} eq $w } @{$v->{selorder}};
    $x .= defined $k ? '    <xccdf:refine-value idref="' . xa($id) . '" selector="' . xa($k) . "\"/>\n" : '    <xccdf:set-value idref="' . xa($id) . '">' . xe($w) . "</xccdf:set-value>\n";
  }
  return "$x  </xccdf:Profile>\n</xccdf:Tailoring>\n";
}

# structure checks, not a schema validation
sub validate {
  my ($file) = @_;
  load_source($file);
  my (@p, %seen);
  my $bad = sub { push @p, $_[0] unless $seen{$_[0]}++ };
  $bad->("Unknown SCAP file type: <$S{root}[0]>.") if !$S{bench} && !@{$S{oval}} && $S{root}[0] !~ /^(?:Tailoring|TestResult|asset-report-collection|oval_results|cpe-list|ocil)$/;
  for my $root (@{$S{oval}}) {
    my %ids;
    for my $sec (grep { $_->[0] =~ /^(?:definitions|tests|objects|states|variables)$/ } kids($root)) {
      for my $e (kids($sec)) { my $id = at($e, 'id'); if ($id eq '') { $bad->("OVAL <$e->[0]> without an id.") } elsif ($ids{$id}++) { $bad->("Duplicate OVAL id: $id") } }
    }
    walk($root, sub {
      my ($n) = @_; my $h = attrs($n);
      for (qw(test_ref definition_ref object_ref state_ref var_ref)) { $bad->("OVAL $_ points to missing $h->{$_}") if defined $h->{$_} && !$ids{$h->{$_}} }
      if (($n->[0] eq 'object_reference' || $n->[0] eq 'filter') && !kids($n)) { my $v = trim(val($n)); $bad->("OVAL $n->[0] points to missing $v") if $v =~ /^oval:/ && !$ids{$v} }
    });
    $bad->('The OVAL file does not say its schema version.') if oval_version($root) eq '';
  }
  if (my $b = $S{bench}) {
    my (%ids, %cl, @rules);
    walk($b, sub {
      my ($e) = @_; my $n = $e->[0];
      my $c = at($e, 'cluster-id'); $cl{$c} = 1 if $c ne '';
      push @rules, $e if $n eq 'Rule';
      return unless $n =~ /^(?:Benchmark|Group|Rule|Value|Profile)$/;
      my $id = at($e, 'id'); my $l = lc $n;
      if ($id eq '') { $bad->("<$n> without an id.") } elsif ($ids{$id}++) { $bad->("Duplicate id: $id") }
      $bad->("XCCDF 1.2 ids must look like xccdf_NAMESPACE_${l}_NAME: $id") if $b->[1] =~ /\/1\.2$/ && $id ne '' && $id !~ /^xccdf_[^_]+_${l}_.+$/;
    });
    $bad->('The benchmark has no <status>.') unless el($b, 'status');
    $bad->('The benchmark has no <version>.') unless el($b, 'version');
    for my $pr (els($b, 'Profile')) {
      my $x = at($pr, 'extends');
      $bad->(at($pr, 'id') . " extends a missing profile: $x") if $x ne '' && !$ids{strip_hash($x)};
      for my $r (grep { $_->[0] =~ /^(?:select|refine-value|set-value|refine-rule)$/ } kids($pr)) { my $i = at($r, 'idref'); $bad->(at($pr, 'id') . ": <$r->[0]> refers to missing $i") unless $ids{$i} || $cl{$i} }
    }
    my %texts = map { at($_, 'id') => 1 } els($b, 'plain-text');
    my %defs;
    for my $r (@rules) {
      my $rid = at($r, 'id');
      walk($r, sub {
        my ($c) = @_; my $n = $c->[0];
        if ($n eq 'check-export') { my $v = at($c, 'value-id'); $bad->("$rid: check-export of missing value $v") unless $ids{$v} }
        elsif ($n eq 'sub') { my $v = at($c, 'idref'); $bad->("$rid: <sub> of missing value $v") unless $ids{$v} || $texts{$v} }
        elsif ($n eq 'check-content-ref') {
          my $h = at($c, 'href'); return if $h =~ m{://};
          my $f = find_file($h);
          if (!$f) { $bad->("$rid: check file not found: $h"); return }
          my $name = at($c, 'name');
          if ($f->[0] eq 'oval_definitions' && $name ne '') {
            my $d = $defs{$f} ||= { map { at($_, 'id') => 1 } map { kids($_) } els($f, 'definitions') };
            $bad->("$rid: OVAL definition not found: $name") unless $d->{$name};
          }
        }
      });
    }
  }
  return @p;
}

# ================================================================ main
my $cmd = shift @ARGV;
fail('scap.pl is run by the scriptix command') unless defined $cmd;
my %o;
while (@ARGV) {
  my $k = shift @ARGV;
  fail("unknown option: $k") unless $k =~ /^--(file|profile|tailoring|set|benchmark|lib|out|rule|skip-rule|csv|type|html|xccdf|arf|select|unselect|title|source)$/;
  my $n = $1;
  fail("$k needs a value") unless @ARGV;
  my $v = shift @ARGV;
  utf8::decode($v) unless $n =~ /^(?:file|tailoring|lib|out|csv|html|xccdf|arf)$/;
  if ($n =~ /^(?:set|rule|skip-rule|select|unselect)$/) { push @{$o{$n}}, $v } else { $o{$n} = $v }
}
my $done = eval {
  if ($cmd eq 'validate') {
    my @p = validate($o{file});
    out(undef, join('', map { "$_\n" } @p));
    print STDERR @p ? scalar(@p) . " problem(s)\n" : "OK\n";
    exit(@p ? 1 : 0);
  }
  if ($cmd eq 'report') {
    my ($rows, $host, $when) = load_rows($o{csv});
    %D = ();
    if (!defined $o{file} && $o{csv} =~ /\.xml$/i) {   # results of XCCDF or ARF often hold the benchmark too
      $o{file} = $o{csv};
      eval { load_doc(\%o); 1 } or do { delete $o{file}; %D = (); %S = () };
      if (defined $o{file} && !defined $o{profile}) {
        ($o{profile}) = map { $_->{id} } grep { defined $RESPROF && $_->{id} eq $RESPROF } @{$D{profiles}};
      }
    }
    elsif (defined $o{file}) {      load_doc(\%o);
      my $n = grep { $_->[1] } match_rows($rows);
      if ($D{prebuilt} || $n * 2 <= @$rows) { my $t = $D{title}; %D = (title => $t); %S = () }
    }
    my $p = defined $D{id} ? find_profile($o{profile}) || default_profile() : undef;
    my ($src) = (defined $o{source} ? $o{source} : $o{csv}) =~ m{([^/]*)$};
    if (defined $o{html}) { my $h = html_report($rows, $p, $host, $when, $src); out($o{html}, $h) }
    spew($o{xccdf}, xccdf_text($rows, $p, $host, $when)) if defined $o{xccdf};
    spew($o{arf}, arf_text($rows, $p, $host, $when)) if defined $o{arf};
    my ($d) = scores($rows, $p);
    printf "%.2f\n", $d->[1] unless defined $o{html} && $o{html} eq '-';
    return 1;
  }
  load_doc(\%o);
  if ($cmd eq 'info') { out($o{out}, info()) }
  elsif ($cmd eq 'compile') {
    my $p = find_profile($o{profile});
    my @it;
    if (!$p && !$D{prebuilt}) {
      $p = default_profile();
      die "pick a profile with --profile:\n" . join('', map { '  ' . short_id($_->{id}, '_profile_') . "  $_->{title}\n" } @{$D{profiles}}) if !%{$p->{selected}} && @{$D{profiles}};
    }
    @it = check_items($p, $o{rule} || [], $o{'skip-rule'} || []);
    die "no rule is selected\n" unless @it;
    my $n = build_script($o{lib}, $o{out}, 'check', 1, @it);
    my $b = $D{file}; $b =~ s/\.xml$//i; $b =~ s/^ssg-//; $b =~ s/-(?:ds(?:-1\.[0-9])?|xccdf|oval)$//;
    my $nm = $b . ($p && $p->{id} ne '' ? '_' . short_id($p->{id}, '_profile_') : '');
    $nm =~ s/[^A-Za-z0-9._-]/_/g; $nm =~ s/^[^A-Za-z0-9]+//; $nm = substr($nm, 0, 60); $nm = 'scap' if $nm eq '';
    out(undef, join("\t", $nm, $n, $p && $p->{title} ne '' ? one_line($p->{title}) : one_line($D{title})) . "\n");
  }
  else {
    my $p = find_profile($o{profile});
    my $q = $p || default_profile();
    if ($cmd eq 'guide') { out($o{out}, guide($q, $q->{selected})) }
    elsif ($cmd eq 'tailor') { out($o{out}, tailor($p, \%o)) }
    elsif ($cmd eq 'fix') {
      my ($failed, %sel);
      %sel = %{$q->{selected}};
      if (defined $o{csv}) {
        my ($rows) = load_rows($o{csv});
        $failed = { map { $_->{id} => 1 } grep { $_->{result} eq 'FAIL' } @$rows };
        for (@{$D{rules}}) { delete $sel{$_->{id}} unless $failed->{safe_id($_->{id}, 0)} || $failed->{safe_id($_->{short}, 0)} }
      }
      my $type = defined $o{type} ? $o{type} : 'bash';
      if ($type eq 'script') {
        my @it = fix_items($q, $failed);
        die "none of these rules has a shell fix\n" unless @it;
        my $n = build_script($o{lib}, $o{out}, 'apply', 0, @it);
        print "$n\n";
      }
      else { out($o{out}, fixes($q, $type, \%sel)) }
    }
    else { die "unknown command\n" }
  }
  1;
};
unless ($done) { my $e = $@; $e =~ s/ at \S+ line \d+\.?\n$/\n/ if $e !~ /\n.*\n/s; chomp $e; fail($e) }
exit 0;
