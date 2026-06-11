#!/usr/bin/perl
# Copyright (c) 2025 Jonas van den Berg
# This file is licensed under the BSD 3-Clause License.

# For usage information read below or run the script without arguments.

use strict;
use warnings;
use DynaLoader;
use File::Spec;
use File::Basename;

sub print_help() {
  print <<'HELP';
Usage:
  mediaremote-adapter.pl FRAMEWORK_PATH [TEST_CLIENT_PATH]
                         [FUNCTION [PARAMS|OPTIONS...]]

FRAMEWORK_PATH:
  Absolute path to the MediaRemoteAdapter.framework directory

TEST_CLIENT_PATH: (optional)
  Absolute path to the MediaRemoteAdapterTestClient executable. Only for "test"

FUNCTION:
  stream   Streams now playing information (as diff by default)
  get      Prints now playing information once with all available metadata
  send     Sends a command to the now playing application
  seek     Seeks to a specific timeline position
  shuffle  Sets the shuffle mode
  repeat   Sets the repeat mode
  speed    Sets the playback speed
  test     Tests if the adapter is entitled to use the MediaRemote framework.
           An exit code other than 0 indicates the adapter is non-functional

PARAMS:
  send(command)
    command: The MRCommand ID as a number (e.g. kMRPlay = 0)
  seek(position)
    position: The timeline position in microseconds
  shuffle(mode)
    mode: The shuffle mode
  repeat(mode)
    mode: The repeat mode
  speed(speed)
    speed: The playback speed

OPTIONS:
  get
    --now: Adds an "elapsedTimeNow" key with an estimation of the current
      elapsed playback time. This estimation may be off by up to a second.
      To determine a more accurate time without polling "get" continuously,
      calculate it using the "elapsedTime" and "timestamp" keys. "elapsedTime"
      contains the elapsed time at the time that is stored in "timestamp".
  stream
    --no-diff: Disable diffing and always dump all metadata
    --debounce=N: Delay in milliseconds to prevent spam (0 by default)
  get, stream
    --micros: Replaces the following time keys with microsecond equivalents
      "duration" -> "durationMicros"
      "elapsedTime" -> "elapsedTimeMicros"
      "elapsedTimeNow" -> "elapsedTimeNowMicros"
      "timestamp" -> "timestampEpochMicros" (converted to epoch time)
    --human-readable, -h: Makes values human-readable. Use only for debugging.
      The JSON output is pretty-printed and the following keys are adapted:
      "artworkData" -> Binary data is truncated to a shorter representation

Examples (script name and framework path omitted):
  stream --no-diff --debounce=100
  send 2    # Toggles play/pause in the media player (kMRATogglePlayPause)
  repeat 3  # Sets the repeat mode to "playlist" (kMRARepeatModePlaylist)

HELP
  exit 0;
}

if (!defined $ARGV[1]) {
  print_help();
}

sub fail {
  my ($error) = @_;
  print STDERR "$error\n";
  exit 1;
}

fail "Framework path not provided" unless @ARGV >= 1;

my $framework_path = shift @ARGV;

# Optionally accept MEDIAREMOTEADAPTER_TEST_CLIENT_PATH path as second argument
my $maybe_helper_path = $ARGV[0] // '';
if ($maybe_helper_path =~ m{/}){
  my $helper_path = shift @ARGV;
  $ENV{MEDIAREMOTEADAPTER_TEST_CLIENT_PATH} = $helper_path;
}

if (!defined $ARGV[0]) {
  print_help();
}

my $framework_basename = File::Basename::basename($framework_path);
fail "Provided path is not a framework: $framework_path"
  unless $framework_basename =~ s/\.framework$//;

my $framework = File::Spec->catfile($framework_path, $framework_basename);
fail "Framework not found at $framework" unless -e $framework;

my $handle = DynaLoader::dl_load_file($framework, 0)
  or fail "Failed to load framework: $framework";
my $function_name = shift @ARGV or fail "Missing function name";
fail "Invalid function name: '$function_name'"
  unless $function_name eq "stream"
  || $function_name eq "get"
  || $function_name eq "send"
  || $function_name eq "seek"
  || $function_name eq "shuffle"
  || $function_name eq "repeat"
  || $function_name eq "speed"
  || $function_name eq "test";

sub parse_options {
  my ($start_index) = @_;
  my %arg_map;
  my $i = $start_index;
  while ($i <= $#ARGV) {
    my $arg = $ARGV[$i];
    if ($arg =~ /^--([a-z\\-]+)(?:=(.*))?$/) {
      my $key = $1;
      my $value = defined $2 ? $2 : undef;
      $arg_map{$key} = $value;
      splice @ARGV, $i, 1;
    }
    elsif ($arg =~ /^-([a-zA-Z]+)$/) {
      my @flags = split //, $1;
      $arg_map{$_} = undef for @flags;
      splice @ARGV, $i, 1;
    }
    else {
      $i++;
    }
  }
  return \%arg_map;
}

sub env_func {
  my $symbol_name = shift;
  return "${symbol_name}_env";
}

sub set_env_param {
  my ($func, $index, $name, $value) = @_;
  $ENV{"MEDIAREMOTEADAPTER_PARAM_${func}_${index}_${name}"} = "$value";
}

sub set_env_option_unsafe {
  my ($name, $value) = @_;
  $name =~ s/-/_/g;
  $ENV{"MEDIAREMOTEADAPTER_OPTION_${name}"} = defined $value ? "$value" : "";
}

sub set_env_option {
  my ($options, $key) = @_;
  my $value = $options->{$key};
  if (defined $value) {
    fail "Unexpected value for option '$key'";
  }
  set_env_option_unsafe($key, $value);
}

sub set_env_option_value {
  my ($options, $key) = @_;
  my $value = $options->{$key};
  if (!defined $value) {
    fail "Missing value for option '$key'";
  }
  set_env_option_unsafe($key, $value);
}

my $symbol_name = "adapter_$function_name";
if ($function_name eq "send") {
  my $id = shift @ARGV;
  fail "Missing ID for '$function_name' command" unless defined $id;
  set_env_param($symbol_name, 0, "command", "$id");
  $symbol_name = env_func($symbol_name);
}
elsif ($function_name eq "stream") {
  my $options = parse_options(0);
  foreach my $key (keys %{$options}) {
    if ($key eq "no-diff") {
      set_env_option($options, $key);
    }
    elsif ($key eq "debounce") {
      set_env_option_value($options, $key);
    }
    elsif ($key eq "micros") {
      set_env_option($options, $key);
    }
    elsif ($key eq "human-readable" || $key eq "h") {
      set_env_option($options, "human-readable");
    }
    else {
      fail "Unrecognized option '$key'";
    }
  }
  $symbol_name = env_func($symbol_name);
}
elsif ($function_name eq "get") {
  my $options = parse_options(0);
  foreach my $key (keys %{$options}) {
    if ($key eq "micros") {
      set_env_option($options, $key);
    }
    elsif ($key eq "human-readable" || $key eq "h") {
      set_env_option($options, "human-readable");
    }
    elsif ($key eq "now") {
      set_env_option($options, $key);
    }
    else {
      fail "Unrecognized option '$key'";
    }
  }
  $symbol_name = env_func($symbol_name);
}
elsif ($function_name eq "seek") {
  my $position = shift @ARGV;
  fail "Missing position for '$function_name' command" unless defined $position;
  set_env_param($symbol_name, 0, "position", "$position");
  $symbol_name = env_func($symbol_name);
}
elsif ($function_name eq "shuffle") {
  my $mode = shift @ARGV;
  fail "Missing mode for '$function_name' command" unless defined $mode;
  set_env_param($symbol_name, 0, "mode", "$mode");
  $symbol_name = env_func($symbol_name);
}
elsif ($function_name eq "repeat") {
  my $mode = shift @ARGV;
  fail "Missing mode for '$function_name' command" unless defined $mode;
  set_env_param($symbol_name, 0, "mode", "$mode");
  $symbol_name = env_func($symbol_name);
}
elsif ($function_name eq "speed") {
  my $speed = shift @ARGV;
  fail "Missing speed for '$function_name' command" unless defined $speed;
  set_env_param($symbol_name, 0, "speed", "$speed");
  $symbol_name = env_func($symbol_name);
}
elsif ($function_name eq "test") {
  $symbol_name = "adapter_test";
}

if (defined shift @ARGV) {
  fail "Too many arguments";
}

my $symbol = DynaLoader::dl_find_symbol($handle, "$symbol_name")
  or fail "Symbol '$symbol_name' not found in $framework";
DynaLoader::dl_install_xsub("main::$function_name", $symbol);

# -----------------------------------------------------------------------------
# Parent-death watchdog (only for the long-running "stream" command).
#
# Once we call into the C `adapter_stream_*` entry below, the Perl interpreter
# is blocked inside the framework's CFRunLoop for the entire stream lifetime
# and cannot poll, select, or run signal handlers. If the parent app
# (boringNotch) dies — crash, force-quit, Xcode "Stop", SIGKILL — macOS
# reparents this Perl process to launchd (PID 1) and it keeps streaming
# MediaRemote events that nobody is reading, indefinitely.
#
# We delegate the watching to a tiny C helper, `pdwatch`, that lives in the
# app bundle next to this script. It uses kqueue(EVFILT_PROC | NOTE_EXIT) to
# block event-driven inside the kernel until the host (or this Perl process)
# exits — zero polling, zero idle CPU/wakes while waiting. When the host
# dies first, pdwatch sends SIGTERM to this Perl interpreter, then SIGKILL
# after a 1-second grace period. When this Perl exits first (clean
# teardown from the host), pdwatch just exits.
#
# Fork or exec failure here is non-fatal: we skip the watchdog and rely on
# the host's own teardown path for cleanup. This also makes the script
# work fine in test/CLI scenarios where `pdwatch` isn't installed.
# -----------------------------------------------------------------------------
if ($function_name eq "stream") {
  my $host_pid = getppid();   # boringNotch process PID
  my $perl_pid = $$;          # our own PID
  if ($host_pid > 1) {
    my $script_dir = File::Basename::dirname(File::Spec->rel2abs(__FILE__));
    my $pdwatch    = File::Spec->catfile($script_dir, "pdwatch");
    if (-x $pdwatch) {
      my $child = fork();
      if (defined $child && $child == 0) {
        # In the watchdog child. Detach STD streams so we don't keep the
        # host's pipes alive, then exec into pdwatch — it never returns
        # from kevent() until one of the PIDs exits.
        $0 = "mediaremote-adapter watchdog";
        open(STDIN,  '<', '/dev/null');
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        exec($pdwatch, $host_pid, $perl_pid);
        exit 1;   # exec failure
      }
      # Parent (this Perl) falls through into the blocking stream call.
    }
  }
}

eval {
  no strict "refs";
  &{"main::$function_name"}();
};
if ($@) {
  fail "Error executing $function_name: $@";
}
