package MonitisMonitorManager;

use 5.008008;
require XML::Simple;
require Monitis;
require Thread;
require URI;
use Thread qw(async);

use strict;
no strict "refs";
use warnings;
use threads::shared;
use URI::Escape;
use MonitisMonitorManager::MonitisConnection;
use MonitisMonitorManager::M3Logger;
use Carp;
use Date::Manip;
use File::Basename;
use JSON;
use Data::Dumper;

#################
### CONSTANTS ###
#################

require Exporter;

our @ISA = qw(Exporter);

# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.

# This allows declaration	use MonitisMonitorManager ':all';
# If you do not need this, moving things directly into @EXPORT or @EXPORT_OK
# will save memory.
our %EXPORT_TAGS = ( 'all' => [ qw(
	
) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(
	
);

our $VERSION = '3.12';

# use the same constant as in the Perl-SDK
use constant DEBUG => $ENV{MONITIS_DEBUG} || 0;

# constants for HTTP statistics
use constant {
	EXECUTION_PLUGIN_DIR => "Execution",
	PARSING_PLUGIN_DIR => "Parsing",
	COMPUTE_PLUGIN_DIR => "Compute",
};

our %monitis_datatypes = ( 'boolean', 1, 'integer', 2, 'string', 3, 'float', 4 );

# a helper variable to signal threads to quit on time
my $condition_loop_stop :shared = 0;

#####################
### CTOR AND DTOR ###
#####################

# constructor
sub new {
	my $class = shift;
	my $self = {@_};
	bless $self, $class;

	# initialize a static variable
	$self->{monitis_datatypes} = \%monitis_datatypes;

	# initialize M3Logger
	$self->{m3logger} = MonitisMonitorManager::M3Logger->instance();
	$self->{m3logger}->set_syslog_logging($self->is("syslog"));
	$self->{m3logger}->log_message ("debug", "M3 starting");

	# open the given XML file
	open (FILE, $self->{configuration_xml} || croak "Failed to open configuration XML: $!");
	my $templated_xml = "";
	while (<FILE>) { $templated_xml .= $_; }

	# run the macros which would change all the %SOMETHING% to a proper value
	run_macros($templated_xml);

	# load execution plugins
	$self->load_plugins_in_directory(
		plugin_table_name => "execution_plugins",
		plugin_directory => EXECUTION_PLUGIN_DIR);

	# load parsing plugins
	$self->load_plugins_in_directory(
		plugin_table_name => "parsing_plugins",
		plugin_directory => PARSING_PLUGIN_DIR);

	# load compute plugins
	$self->load_plugins_in_directory(
		plugin_table_name => "compute_plugins",
		plugin_directory => COMPUTE_PLUGIN_DIR);

	my $xml_parser = XML::Simple->new(ForceArray => 1);
	$self->{config_xml} = $xml_parser->XMLin($templated_xml);

	# a shortcut to the agents structure
	$self->{agents} = $self->{config_xml}->{agent};

	# initialize MonitisConnection - async class for Monitis interaction
	$self->{monitis_connection} = MonitisMonitorManager::MonitisConnection->new(
		apikey => "$self->{config_xml}->{apicredentials}[0]->{apikey}",
		secretkey => "$self->{config_xml}->{apicredentials}[0]->{secretkey}",
	);

	# automatically add monitors
	$self->add_agents();

	return $self;
}

# destructor
sub DESTROY {
	my $self = shift;

	# call parent dtor (not that there is any, but just to make it clean)
	$self->SUPER::DESTROY if $self->can("SUPER::DESTROY");
	# umn, why would destroy be called multiple times?
	# because we pass $self to every running thread, so shallow copying
	# will occur. only the main thread will have MonitisConnection defined
	# though
	defined($self->{monitis_connection}) and $self->{monitis_connection}->stop();
}

##########################
### CORE FUNCTIONALITY ###
##########################

# add a single monitor
sub add_monitor {
	my $self = shift;
	my ($args) = {@_};
	my $agent_name = $args->{agent_name};
	my $monitor_name = $args->{monitor_name};

	my $monitor_xml_path = $self->{agents}->{$agent_name}->{monitor}->{$monitor_name};

	# get the monitor tag
	my $monitor_tag = $self->get_monitor_tag(
		agent_name => $agent_name,
		monitor_name => $monitor_name);
	my $result_params = "";
	my $additional_result_params = "";
	foreach my $metric_name (keys %{$monitor_xml_path->{metric}}) {
		if ($self->metric_name_not_reserved($metric_name)) {
			my $uom = $monitor_xml_path->{metric}->{$metric_name}->{uom}[0];
			my $metric_type = $monitor_xml_path->{metric}->{$metric_name}->{type}[0];
			my $data_type = ${ $self->{monitis_datatypes} }{$metric_type} or croak "Incorrect data type '$metric_type'";
			if (defined($monitor_xml_path->{metric}->{$metric_name}->{additional})) {
				# it's an additional parameter
				$additional_result_params .= "$metric_name:$metric_name:$uom:$data_type;";
			} else {
				$result_params .= "$metric_name:$metric_name:$uom:$data_type;";
			}
		}
	}

	# monitor type (can also be undef)
	my $monitor_type = $self->{agents}->{$agent_name}->{monitor}->{$monitor_name}->{type};

	# we'll let external execution plugins dictate if they want to expose
	# additional counters (HTTP statistics for instance)
	# find the relevant execution plugin and execute its additional counters
	# function
	foreach my $execution_plugin (keys %{$self->{execution_plugins}} ) {
		if (defined($monitor_xml_path->{$execution_plugin}[0])) {
			foreach my $execution_xml_base (@{$monitor_xml_path->{$execution_plugin}}) {
				# it's called a URI since it can be anything, from a command line
				# executable, URL, SQL command...
				$self->{m3logger}->log_message ("debug", "Calling extra_counters_cb for plugin: '$execution_plugin', monitor_name->'$monitor_name'");
				# executable, URL, SQL command...
				$result_params .= $self->{execution_plugins}{$execution_plugin}->extra_counters_cb($self->{monitis_datatypes}, $execution_xml_base);
			}
		}
	}

	# remove redundant last ';'
	$result_params =~ s/;$//;

	# a simple sanity check
	if ($result_params eq "") {
		$self->{m3logger}->log_message ("info", "ResultParams are empty for monitor '$monitor_name'... Skipping!");
		return;
	}

	$self->{m3logger}->log_message ("debug", "Adding monitor '$monitor_name' with metrics '$result_params'");

	# call Monitis using the api context provided
	if ($self->is("dry_run")) {
		# don't output this line if just testing configuration
		not $self->is("test_config") and $self->{m3logger}->log_message ("info", "This is a dry run, the monitor '$monitor_name' was not really added.");
	} else {
		my @add_monitor_optional_params;
		defined($monitor_type) && push @add_monitor_optional_params, type => $monitor_type;
		if($additional_result_params ne "") { push @add_monitor_optional_params, additionalResultParams => $additional_result_params; }
		$self->add_monitor_raw(
			monitor_name => $monitor_name,
			monitor_tag =>  $monitor_tag,
			result_params =>  $result_params,
			optional_params =>  \@add_monitor_optional_params);
	}
}

# add all monitors for all agents
sub add_agents {
	my $self = shift;

	# iterate on agents and add them one by one
	foreach my $agent_name (keys %{$self->{agents}}) {
		$self->{m3logger}->log_message ("debug", "Adding agent '$agent_name'");
		$self->add_agent_monitors(agent_name => $agent_name);
	}
}

# add one agent
sub add_agent_monitors {
	my $self = shift;
	my ($args) = {@_};
	my $agent_name = $args->{agent_name};
	
	# iterate on all monitors and add them
	foreach my $monitor_name (keys %{$self->{agents}->{$agent_name}->{monitor}} ) {
		$self->{m3logger}->log_message ("debug", "Adding monitor '$monitor_name' for agent '$agent_name'");
		$self->add_monitor(
			agent_name => $agent_name,
			monitor_name =>  $monitor_name);
	}
}

# invoke a single monitor
sub invoke_monitor {
	my $self = shift;
	my ($args) = {@_};
	my $agent_name = $args->{agent_name};
	my $monitor_name = $args->{monitor_name};

	# get the xml path for that monitor
	my $monitor_xml_path = $self->{agents}->{$agent_name}->{monitor}->{$monitor_name};

	my $output = "";
	my $execution_called = undef;

	# result set hash
	my %results = ();
	my %additional_results = ();

	# if just testing monitors - print a nice message
	($self->is("test_config")) and $self->{m3logger}->log_message ("info", "Testing monitor '$monitor_name': ");
	my $config_ok = 1;

	# find the relevant execution plugin and execute it
	# TODO execution might be out of order in some cases
	foreach my $execution_plugin (keys %{$self->{execution_plugins}} ) {
		if (defined($monitor_xml_path->{$execution_plugin}[0])) {
			foreach my $execution_xml_base (@{$monitor_xml_path->{$execution_plugin}}) {
				# it's called a URI since it can be anything, from a command line
				# executable, URL, SQL command...
				$self->{m3logger}->log_message ("debug", "Calling execution plugin: '$execution_plugin', execution_xml_base->'$execution_xml_base', monitor_name->'$monitor_name'");
				my %returned_results = ();
				if ($self->is("test_config")) {
					my %tmp_hash = ();
					eval {
						$self->{execution_plugins}{$execution_plugin}->get_config($execution_xml_base, \%tmp_hash);
					};
					if ($@) {
						$self->{m3logger}->log_message ("err", "Configuration error: $@");
						$config_ok = 0;
					}
				} else {
					$output .= $self->{execution_plugins}{$execution_plugin}->execute($execution_xml_base, \%returned_results, $monitor_name);
					$output .= "\n";

					# merge the returned results into the main %results hash
					@results{keys %returned_results} = values %returned_results;

					# we will not break execution as we might execute a few plugins
					$execution_called = 1;
				}
			}
		}
	}

	# just testing configuration? - alright, quit!
	if ($self->is("test_config")) {
		($config_ok == 1) and $self->{m3logger}->log_message ("info", "Monitor '$monitor_name' -> Configuration is OK");
		return;
	}

	# did we call anything at all??
	if (!defined($execution_called)) {
		croak "Could not find proper execution plugin for monitor '$monitor_name'";
	}

	my $retval = 1;
	# if mass load is set, we'll handle the lines one by one
	if ($self->is("mass_load")) {
		foreach my $line (split /[\r\n]+/, $output) {
			$retval = $self->handle_output_chunk(
				agent_name => $agent_name,
				monitor_xml_path => $monitor_xml_path,
				monitor_name => $monitor_name,
				ref_results => \%results,
				ref_additional_results => \%additional_results,
				output => $line);
		}
	} else {
		$retval = $self->handle_output_chunk(
			agent_name => $agent_name,
			monitor_xml_path => $monitor_xml_path,
			monitor_name => $monitor_name,
			ref_results => \%results,
			ref_additional_results => \%additional_results,
			output => $output);
	}
}

# handle a chunk of output after executing plugins
# basically we parse stuff here...
sub handle_output_chunk {
	my $self = shift;
	my ($args) = {@_};
	my $agent_name = $args->{agent_name};
	my $monitor_name = $args->{monitor_name};
	my $monitor_xml_path = $args->{monitor_xml_path};
	my $output = $args->{output};
	my %results = %{$args->{ref_results}};
	my %additional_results = %{$args->{ref_additional_results}};

	foreach my $metric_name (keys %{$monitor_xml_path->{metric}} ) {
		# call the relevant parsing plugin
		my %returned_results = ();

		# run the parsing plugin one by one
		foreach my $potential_parsing_plugin (keys %{$monitor_xml_path->{metric}->{$metric_name}}) {
			if (defined($self->{parsing_plugins}{$potential_parsing_plugin})) {
				$self->{m3logger}->log_message ("debug", "Calling parsing plugin: '$potential_parsing_plugin'");
				$self->{parsing_plugins}{$potential_parsing_plugin}->parse($metric_name, $monitor_xml_path->{metric}->{$metric_name}, $output, \%returned_results);
			}
		}

		# call the relevant compute plugins
		# TODO computation might be out of order in some cases when chaining
		foreach my $potential_compute_plugin (keys %{$monitor_xml_path->{metric}->{$metric_name}}) {
			if (defined($self->{compute_plugins}{$potential_compute_plugin})) {
				foreach my $code (@{$monitor_xml_path->{metric}->{$metric_name}->{$potential_compute_plugin}}) {
					$self->{m3logger}->log_message ("debug", "Calling compute plugin: '$potential_compute_plugin'");
					my $code = $monitor_xml_path->{metric}->{$metric_name}->{$potential_compute_plugin}[0];
					$self->{compute_plugins}{$potential_compute_plugin}->compute($agent_name, $monitor_name, $monitor_xml_path, $code, \%returned_results);
				}
			}
		}

		# merge the returned results into the main %results hash
		if (defined($monitor_xml_path->{metric}->{$metric_name}->{additional})) {
			@additional_results{keys %returned_results} = values %returned_results;
		} else {
			@results{keys %returned_results} = values %returned_results;
		}
	}

	# TODO 'MONITIS_CHECK_TIME' hardcoded
	# if MONITIS_CHECK_TIME is defined, use it as the timestamp for updating data
	# note: @checktime can be empty, then we'll calculate the current timestamp
	my @checktime;
	if (defined($results{MONITIS_CHECK_TIME})) {
		if (int($results{MONITIS_CHECK_TIME}) == $results{MONITIS_CHECK_TIME}) {
			# no need for date manipulation
			push @checktime, "checktime" => $results{MONITIS_CHECK_TIME};
		} else {
			my $date = new Date::Manip::Date;
			$date->parse($results{MONITIS_CHECK_TIME});
			# checktime here is seconds, update_data_for_monitor will multiply by
			# 1000 to make it milliseconds
			push @checktime, "checktime" => $date->secs_since_1970_GMT();
		}
		# and remove it from the hash
		delete $results{MONITIS_CHECK_TIME};
	}

	# format results
	my $formatted_results = format_results(\%results);
	my $formatted_additional_results = format_results_json(\%additional_results);

	return $self->update_data_for_monitor(
		agent_name => $agent_name,
		monitor_name => $monitor_name,
		results => $formatted_results,
		additional_results => $formatted_additional_results,
		@checktime);
}

# update data for a monitor, calling Monitis API
sub update_data_for_monitor {
	my $self = shift;
	my ($args) = {@_};
	my $agent_name = $args->{agent_name};
	my $monitor_name = $args->{monitor_name};
	my $results = $args->{results};
	my $additional_results = $args->{additional_results};

	# did the user specify a checktime?
	my $checktime;
	if (defined($args->{checktime})) {
		$checktime = $args->{checktime} * 1000;
	} else {
		# get the time now (time returns time in seconds, multiply by 1000
		# for miliseconds)
		$checktime = time * 1000;
	}

	# sanity check of results...
	if ($results eq "") {
		$self->{m3logger}->log_message ("info", "Result set is empty! did it parse well? - Will not update any data!"); 
		return;
	}

	if ($self->is("dry_run")) {
		$self->{m3logger}->log_message ("info", "OK");
		$self->{m3logger}->log_message ("info", "This is a dry run, data for monitor '$monitor_name' was not really updated.");
		return;
	}

	# queue it on MonitisConnection which will handle the rest
	my $monitor_tag = $self->get_monitor_tag(
		agent_name => $agent_name,
		monitor_name => $monitor_name);
	$self->update_data_for_monitor_raw(
		agent_name => $agent_name,
		monitor_name => $monitor_name,
		monitor_tag => $monitor_tag,
		checktime => $checktime,
		results => $results,
		additional_results => $additional_results);
}

# invoke all agents, one by one
sub invoke_agents {
	my $self = shift;
	foreach my $agent_name (keys %{$self->{agents}} ) {
		$self->invoke_agent_monitors(agent_name => $agent_name);
	}
}

# invoke all monitors, one by one
sub invoke_agent_monitors {
	my $self = shift;
	my ($args) = {@_};
	my $agent_name = $args->{agent_name};
	foreach my $monitor_name (keys %{$self->{agents}->{$agent_name}->{monitor}}) {
		$self->invoke_monitor(
			agent_name => $agent_name,
			monitor_name => $monitor_name);
	}
}

# signals threads to stop execution
sub agents_loop_stop {
	MonitisMonitorManager::M3Logger->instance()->log_message ("info", "Stopping execution...");
	lock($condition_loop_stop);
	$condition_loop_stop = 1;
	cond_broadcast($condition_loop_stop);
}

# invoke all agents in a loop with timers enabled
sub invoke_agents_loop {
	my $self = shift;
	# initialize all the agents
	my @threads = ();

	foreach my $agent_name (keys %{$self->{agents}} ) {
		push @threads, threads->create(\&invoke_agent_monitors_loop, $self, agent_name => $agent_name);
	}
	my $running_threads = @threads;

	# register SIGINT to stop the loop
	local $SIG{'INT'} = \&MonitisMonitorManager::agents_loop_stop;

	do {
		foreach my $thread (@threads) {
			if($thread->is_joinable()) {
				$thread->join();
				$self->{m3logger}->log_message ("debug", "Thread '$thread' has quitted.");
				$running_threads--;
			}
		}
		sleep 1;
	} while($running_threads > 0);
}

# invoke all monitors of an agent in a loop, taking care to sleep between
# executions
sub invoke_agent_monitors_loop {
	my $self = shift;
	my ($args) = {@_};
	my $agent_name = $args->{agent_name};
	my $agent_interval = $self->{agents}->{$agent_name}->{interval};
	$self->{m3logger}->log_message ("debug", "Agent '$agent_name' will be invoked every '$agent_interval' seconds'");

	# this loop will break when the user will hit ^C (SIGINT)
	do {
		foreach my $monitor_name (keys %{$self->{agents}->{$agent_name}->{monitor}}) {
			$self->invoke_monitor(
				agent_name => $agent_name,
				monitor_name => $monitor_name);
		}
		lock($condition_loop_stop);
		cond_timedwait($condition_loop_stop, time() + $agent_interval);
	} while(not $condition_loop_stop);
}

#####################
### RAW FUNCTIONS ###
#####################

# handles a raw command (add_monitor, update_data)
sub handle_raw_command {
	my $self = shift;
	my ($args) = {@_};
	my $raw_command = $args->{raw_command};

	$self->{m3logger}->log_message ("debug", "Raw command is: '$raw_command'");
	my (@raw_parameters) = split /\s+/, $raw_command;
	my $command = shift @raw_parameters;

	# a quick debug message
	$self->{m3logger}->log_message ("debug", "Handling raw command: '$command'");

	for ($command) {
		/add_monitor/ and do {
			my $monitor_name = shift @raw_parameters;
			my $monitor_tag = shift @raw_parameters;
			my $result_params = shift @raw_parameters;
			my $additional_result_params = shift @raw_parameters;
			my @optional_parameters;
			if($additional_result_params ne "") { push @optional_parameters, additionalResultParams => $additional_result_params; }
			$self->add_monitor_raw(
				monitor_name => $monitor_name,
				monitor_tag => $monitor_tag,
				result_params =>  $result_params,
				optional_params =>  \@optional_parameters);
		};
		/update_data/ and do {
			my $monitor_name = shift @raw_parameters;
			my $monitor_tag = shift @raw_parameters;
			my $results = shift @raw_parameters;
			my $additional_results = shift @raw_parameters;
			$self->update_data_for_monitor_raw(
				monitor_name => $monitor_name,
				monitor_tag => $monitor_tag,
				checktime => time * 1000,
				results => $results,
				additional_results => $additional_results);
		};
		/list_monitors/ and do {
			$self->list_monitors_raw();
		};
		/delete_monitor/ and do {
			my $monitor_id = shift @raw_parameters;
			$self->delete_monitor_raw(monitor_id => $monitor_id);
		};
	}
}

# updated raw data for monitor
sub add_monitor_raw {
	my $self = shift;

	# simply forward the parameters!
	$self->{monitis_connection}->add_monitor(@_);
}

# list monitors
sub list_monitors_raw {
	my $self = shift;
	my @monitors = $self->{monitis_connection}->list_monitors();
	my $i = 0;

	printf("ID   |Name           |Tag                      |Type           |\n");
	printf("-----|---------------|-------------------------|---------------|\n");
	while (defined($monitors[0][$i])) {
		my ($monitor_name) = $monitors[0][$i]->{name};
		my ($monitor_type) = $monitors[0][$i]->{type};
		my ($monitor_tag) = $monitors[0][$i]->{tag};
		my ($monitor_id) = $monitors[0][$i]->{id};
		printf("%-5s|%-15s|%-25s|%-15s|\n", $monitor_id, $monitor_name, $monitor_tag, $monitor_type);
		$i++;
	}
}

# delete a monitor
sub delete_monitor_raw {
	my $self = shift;
	$self->{monitis_connection}->delete_monitor(@_);
}

# update data for a monitor, the internal function
sub update_data_for_monitor_raw {
	my $self = shift;
	$self->{monitis_connection}->queue(@_);
}


###############################
### SMALL UTILITY FUNCTIONS ###
###############################

# a simple function to dynamically load all perl packages in a given
# directory
sub load_plugins_in_directory {
	my $self = shift;
	my ($args) = {@_};	
	my $plugin_table_name = $args->{plugin_table_name};
	my $plugin_directory = $args->{plugin_directory};

	# initialize a new plugin table
	$self->{$plugin_table_name} = ();

	# TODO a little ugly - but this is how we're going to discover where M3
	# was installed...
	my $m3_perl_module_directory = dirname($INC{"MonitisMonitorManager.pm"}) . "/MonitisMonitorManager";
	my $full_plugin_directory = $m3_perl_module_directory . "/" . $plugin_directory;
	# iterate on all plugins in directory and load them
	foreach my $plugin_file (<$full_plugin_directory/*.pm>) {
		my $plugin_name = "MonitisMonitorManager::" . $plugin_directory . "::" . basename($plugin_file);
		$plugin_name =~ s/\.pm$//g;
		# load the plugin
		eval {
			require "$plugin_file";
			$plugin_name->name();
		};
		if ($@) {
			croak "error: $@";
		} else {
			$self->{m3logger}->log_message ("debug", "Loading plugin '" . $plugin_name . "'->'" . $plugin_name->name() . "'");
			$self->{$plugin_table_name}{$plugin_name->name()} = "$plugin_name";
		}
	}
}


# tests an attribute, such as 'dry_run', 'mass_load', 'test_config' etc.
sub is {
	my ($self, $attribute) = @_;
	if (defined($self->{$attribute}) and $self->{$attribute} == 1) {
		return 1;
	} else {
		return 0;
	}
}

# print the XML after it was templated
sub templated_xml {
	my $self = shift;
	my $xmlout = XML::Simple->new(RootName => 'config');
	return $xmlout->XMLout($self->{config_xml});
}

# formats a monitor tag from a name
sub get_monitor_tag {
	my $self = shift;
	my ($args) = {@_};
	my $agent_name = $args->{agent_name};
	my $monitor_name = $args->{monitor_name};

	# if monitor tag is defined, use it!
	if (defined ($self->{agents}->{$agent_name}->{monitor}->{$monitor_name}->{tag}) ) {
		my $monitor_tag = $self->{agents}->{$agent_name}->{monitor}->{$monitor_name}->{tag};
		$self->{m3logger}->log_message ("debug", "Obtained monitor tag '$monitor_tag' from XML");
		return $monitor_tag;
	} else {
		# make a monitor tag from name
		{ $_ = $monitor_name; s/ /_/g; return $_ }
	}
}

# formats the hash of results into a string
sub format_results(%) {
	my (%results) = %{$_[0]};
	my $formatted_results = "";
	foreach my $key (keys %results) {
		$formatted_results .= $key . ":" . uri_escape($results{$key}) . ";";
	}
	# remove redundant last ';'
	$formatted_results =~ s/;$//;
	return $formatted_results;
}

# formats the hash of results into a string
sub format_results_json(%) {
	my (%results) = %{$_[0]};
	return "[" . encode_json(\%results) . "]";
}

# simply replaces the %SOMETHING% with the relevant
# return of a defined function
sub run_macros() {
	$_[0] =~ s/%(\w+)%/replace_template($1)/eg;
}

# macro functions
sub replace_template($) {
	my ($template) = @_;
	my $callback = "_get_$template";
	return &$callback;
}

sub metric_name_not_reserved($$) {
	my $self = shift;
	my ($metric_name) = @_;
	return $metric_name ne "MONITIS_CHECK_TIME";
}


# Preloaded methods go here.

1;
__END__
# Below is stub documentation for your module. You'd better edit it!

=head1 NAME

Monitis Monitor Manager => MMM => M3

M3 is the shortened name for Monitis Monitor Manager.

This Perl module helps you manage Custom Monitors on Monitis (www.monitis.com).

=head1 SYNOPSIS

  use MonitisMonitorManager;

  # dry run dictates whether to upload data to Monitis - yes or no
  my $dry_run = 0;

  # configuration_xml is a file with the configuration XML, refer to some
  # examples here: https://github.com/monitisexchange/Monitis-Linux-Scripts/tree/master/M3v3/monitis-m3/usr/local/share/monitis-m3/sample_config
  my $configuration_xml = "/etc/m3.d/config.xml";

  # test_config dictates whether to just test the configuration or actually
  # do a proper run
  my $test_config = 0;

  # initialize the M3 instance
  my $M3 = MonitisMonitorManager->new(
    configuration_xml => $xmlfile,
    dry_run => $dry_run,
    test_config => $test_config);

  # handle a raw command in the form of:
  # 'add_monitor memory memory free:free:Bytes:2;active:active:Bytes:2'
  # 'update_data memory memory free:305594368;active:879394816'
  $M3->handle_raw_command($raw);

  # runs just one iteration of the agents defined in the XML
  $M3->invoke_agents();

  # invoke the agents in a loop (using the defined interval in the XML)
  $M3->invoke_agents_loop();

=head1 DESCRIPTION

For full proper documentation please refer to:
https://github.com/monitisexchange/Monitis-Linux-Scripts/blob/master/M3v3/README.md

M3 Perl module comes with an init.d service. If you're using a RPM or DEB
package then you're good to do, however the CPAN installation will not take
care of this...
Find it here:
https://github.com/monitisexchange/Monitis-Linux-Scripts/tree/master/M3v3

=head2 EXPORT

MonitisMonitorManager

=head1 SEE ALSO

See also Monitis' blog with entries about M3:
http://blog.monitis.com/index.php/tag/m3/

Monitis main website:
http://www.monitis.com

Github repository:
https://github.com/monitisexchange/Monitis-Linux-Scripts/tree/master/M3v3

=head1 AUTHOR

Dan Fruehauf, E<lt>malkodan@gmail.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2012 by Dan Fruehauf

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.14.2 or,
at your option, any later version of Perl 5 you may have available.


=cut
