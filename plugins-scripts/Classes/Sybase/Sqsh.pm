package Classes::Sybase::Sqsh;
our @ISA = qw(Classes::Sybase);
use strict;
use File::Basename;

sub create_cmd_line {
  my $self = shift;
  my @args = ();
  if ($self->opts->server) {
    push (@args, sprintf "-S '%s'", $self->opts->server);
  } elsif ($self->opts->hostname) {
    push (@args, sprintf "-S '%s:%d'", $self->opts->hostname, $self->opts->port || 1433);
  } else {
    $self->add_critical("-S oder -H waere nicht schlecht");
  }
  push (@args, sprintf "-U '%s'", $self->opts->username);
  push (@args, sprintf "-P '%s'",
      $self->decode_rfc3986($self->opts->password));
  push (@args, sprintf "-i '%s'",
      $Monitoring::GLPlugin::DB::sql_commandfile);
  push (@args, sprintf "-o '%s'",
      $Monitoring::GLPlugin::DB::sql_resultfile);
  if ($self->opts->currentdb) {
    push (@args, sprintf "-D '%s'", $self->opts->currentdb);
  }
  push (@args, sprintf "-h -s '|' -m bcp");
  $Monitoring::GLPlugin::DB::session =
      sprintf '"%s" %s', $self->{extcmd}, join(" ", @args);
}

sub check_connect {
  my $self = shift;
  my $stderrvar;
  if (! $self->find_extcmd("sqsh", "SQL_HOME")) {
    $self->add_unknown("sqsh command was not found");
    return;
  }
  $self->create_extcmd_files();
  $self->create_cmd_line();
  eval {
    $self->set_timeout_alarm($self->opts->timeout - 1, sub {
      die "alrm";
    });
    *SAVEERR = *STDERR;
    open OUT ,'>',\$stderrvar;
    *STDERR = *OUT;
    $self->{tic} = Time::HiRes::time();
    my $answer = $self->fetchrow_array(q{
        SELECT 'schnorch'
    });
    die unless defined $answer and $answer eq 'schnorch';
    $self->{tac} = Time::HiRes::time();
    *STDERR = *SAVEERR;
  };
  if ($@) {
    if ($@ =~ /alrm/) {
      $self->add_critical(
          sprintf "connection could not be established within %s seconds",
          $self->opts->timeout);
    } else {
      $self->add_critical($@);
    }
  } elsif ($stderrvar && $stderrvar =~ /can't change context to database/) {
    $self->add_critical($stderrvar);
  } else {
    $self->set_timeout_alarm($self->opts->timeout - ($self->{tac} - $self->{tic}));
  }
}

sub write_extcmd_file {
  my $self = shift;
  my $sql = shift;
  open CMDCMD, "> $Monitoring::GLPlugin::DB::sql_commandfile";
  printf CMDCMD "%s\n", $sql;
  printf CMDCMD "go\n";
  close CMDCMD;
}

sub fetchrow_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my @row = ();
  my $stderrvar = "";
  foreach (@arguments) {
    # replace the ? by the parameters
    if (/^\d+$/) {
      $sql =~ s/\?/$_/;
    } else {
      $sql =~ s/\?/'$_'/;
    }
  }
  $self->set_variable("verbosity", 2);
  $self->debug(sprintf "SQL (? resolved):\n%s\nARGS:\n%s\n",
      $sql, Data::Dumper::Dumper(\@arguments));
  $self->write_extcmd_file($sql);
  *SAVEERR = *STDERR;
  open OUT ,'>',\$stderrvar;
  *STDERR = *OUT;
  $self->debug($Monitoring::GLPlugin::DB::session);
  my $exit_output = `$Monitoring::GLPlugin::DB::session`;
  *STDERR = *SAVEERR;
  if ($?) {
    my $output = do { local (@ARGV, $/) = $Monitoring::GLPlugin::DB::sql_resultfile; my $x = <>; close ARGV; $x } || '';
    $self->debug(sprintf "stderr %s", $stderrvar) ;
    $self->add_warning($stderrvar);
  } else {
    my $output = do { local (@ARGV, $/) = $Monitoring::GLPlugin::DB::sql_resultfile; my $x = <>; close ARGV; $x } || '';
    @row = map { $self->convert_scientific_numbers($_) }
        map { s/^\s+([\.\d]+)$/$1/g; $_ }         # strip leading space from numbers
        map { s/\s+$//g; $_ }                     # strip trailing space
        split(/\|/, (map { s/^\|//; $_; } grep {! /^\s*$/ } split(/\n/, $output)
)[0]);
    $self->debug(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper(\@row));
  }
  if ($@) {
    $self->debug(sprintf "bumm %s", $@);
    $self->add_critical($@);
  }
  return $row[0] unless wantarray;
  return @row;
}

sub fetchall_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $rows = [];
  my $stderrvar = "";
  foreach (@arguments) {
    # replace the ? by the parameters
    if (/^\d+$/) {
      $sql =~ s/\?/$_/;
    } else {
      $sql =~ s/\?/'$_'/;
    }
  }
  $self->set_variable("verbosity", 2);
  $self->debug(sprintf "SQL (? resolved):\n%s\nARGS:\n%s\n",
      $sql, Data::Dumper::Dumper(\@arguments));
  $self->write_extcmd_file($sql);
  *SAVEERR = *STDERR;
  open OUT ,'>',\$stderrvar;
  *STDERR = *OUT;
  $self->debug($Monitoring::GLPlugin::DB::session);
  my $exit_output = `$Monitoring::GLPlugin::DB::session`;
  *STDERR = *SAVEERR;
  if ($?) {
    my $output = do { local (@ARGV, $/) = $Monitoring::GLPlugin::DB::sql_resultfile; my $x = <>; close ARGV; $x } || '';
    $self->debug(sprintf "stderr %s", $stderrvar) ;
    $self->add_warning($stderrvar) if $stderrvar;
    $self->add_warning($output);
  } else {
    my $output = do { local (@ARGV, $/) = $Monitoring::GLPlugin::DB::sql_resultfile; my $x = <>; close ARGV; $x } || '';
    my @rows = map { [
        map { $self->convert_scientific_numbers($_) }
        map { s/^\s+([\.\d]+)$/$1/g; $_ }
        map { s/\s+$//g; $_ }
        split /\|/
    ] } grep { ! /^\d+ rows selected/ }
        grep { ! /^\d+ [Zz]eilen ausgew / }
        grep { ! /^Elapsed: / }
        grep { ! /^\s*$/ } map { s/^\|//; $_; } split(/\n/, $output);
    $rows = \@rows;
    $self->debug(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper($rows));
  }
  return @{$rows};
}

sub execute {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $rows = [];
  my $stderrvar = "";
  foreach (@arguments) {
    # replace the ? by the parameters
    if (/^\d+$/) {
      $sql =~ s/\?/$_/;
    } else {
      $sql =~ s/\?/'$_'/;
    }
  }
  $self->set_variable("verbosity", 2);
  $self->debug(sprintf "EXEC (? resolved):\n%s\nARGS:\n%s\n",
      $sql, Data::Dumper::Dumper(\@arguments));
  $self->write_extcmd_file($sql);
  *SAVEERR = *STDERR;
  open OUT ,'>',\$stderrvar;
  *STDERR = *OUT;
  $self->debug($Monitoring::GLPlugin::DB::session);
  my $exit_output = `$Monitoring::GLPlugin::DB::session`;
  *STDERR = *SAVEERR;
  if ($?) {
    my $output = do { local (@ARGV, $/) = $Monitoring::GLPlugin::DB::sql_resultfile; my $x = <>; close ARGV; $x } || '';
    $self->debug(sprintf "stderr %s", $stderrvar) ;
    $self->add_warning($stderrvar) if $stderrvar;
    $self->add_warning($output);
  } else {
    my $output = do { local (@ARGV, $/) = $Monitoring::GLPlugin::DB::sql_resultfile; my $x = <>; close ARGV; $x } || '';
    my @rows = map { [
        map { $self->convert_scientific_numbers($_) }
        map { s/^\s+([\.\d]+)$/$1/g; $_ }
        map { s/\s+$//g; $_ }
        split /\|/
    ] } grep { ! /^\d+ rows selected/ }
        grep { ! /^\d+ [Zz]eilen ausgew / }
        grep { ! /^Elapsed: / }
        grep { ! /^\s*$/ } map { s/^\|//; $_; } split(/\n/, $output);
    $rows = \@rows;
    $self->debug(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper($rows));
  }
  return @{$rows};
}

sub decode_rfc3986 {
  my $self = shift;
  my $password = shift;
  eval {
    no warnings 'all';
    $password = $Monitoring::GLPlugin::plugin->{opts}->decode_rfc3986($password);
  };
  # we call '...%s/%s@...' inside backticks where the second %s is the password
  # abc'xcv -> ''abc'\''xcv''
  # abc'`xcv -> ''abc'\''\`xcv''
  if ($password && $password =~ /'/) {
    $password = "'".join("\\'", map { "'".$_."'"; } split("'", $password))."'";
  }
  return $password;
}

sub add_dbi_funcs {
  my $self = shift;
  $self->SUPER::add_dbi_funcs();
  {
    no strict 'refs';
    *{'Monitoring::GLPlugin::DB::create_cmd_line'} = \&{"Classes::Sybase::Sqsh::create_cmd_line"};
    *{'Monitoring::GLPlugin::DB::write_extcmd_file'} = \&{"Classes::Sybase::Sqsh::write_extcmd_file"};
    *{'Monitoring::GLPlugin::DB::decode_rfc3986'} = \&{"Classes::Sybase::Sqsh::decode_rfc3986"};
    *{'Monitoring::GLPlugin::DB::fetchall_array'} = \&{"Classes::Sybase::Sqsh::fetchall_array"};
    *{'Monitoring::GLPlugin::DB::fetchrow_array'} = \&{"Classes::Sybase::Sqsh::fetchrow_array"};
    *{'Monitoring::GLPlugin::DB::execute'} = \&{"Classes::Sybase::Sqsh::execute"};
  }
}

