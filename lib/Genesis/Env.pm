package Genesis::Env;
use strict;
use warnings;
use utf8;

use base 'Genesis::Base'; # for _memoize

use Genesis;
use Genesis::BOSH::Director;
use Genesis::BOSH::CreateEnvProxy;
use Genesis::UI;
use Genesis::IO qw/DumpYAML LoadFile/;

use JSON::PP qw/encode_json decode_json/;
use POSIX qw/strftime/;
use Digest::file qw/digest_file_hex/;
use Time::Seconds;

### Class Methods {{{

# new - create a raw Genesis::Env object {{{
sub new {
	# Do not call directly, use create or load instead
	my ($class, %opts) = @_;

	# validate call
	for (qw(name top)) {
		bug("No '$_' specified in call to Genesis::Env->new!!")
			unless $opts{$_};
	}

	# drop the YAML suffix
	$opts{name} =~ s/\.yml$//;
	$opts{file} = "$opts{name}.yml";

	# environment names must be valid.
	my $err = _env_name_errors($opts{name});
	bail("#R{[ERROR]} Bad environment name '$opts{name}': %s", $err) if $err;

	# make sure .genesis is good to go
	bail("#R{[ERROR]} No deployment type specified in .genesis/config!\n")
		unless $opts{top}->type;

	$opts{__tmp} = workdir;
	return bless(\%opts, $class);
}

# }}}
# load - return an Genesis::Env object represented by a environment file {{{
sub load {
	my ($class,%opts) = @_;

	bug("No '$_' specified in call to Genesis::Env->load!!")
		for (grep {! $opts{$_}} qw/name top/);

	my $env = $class->new(get_opts(\%opts, qw(name top)));
	my (@errors, @config_warnings, @deprecations);
	while (1) {
		push(@errors, sprintf(
			"Environment file #C{%s} does not exist.",
			$env->{file}
		)) unless -f $env->path($env->{file});
		last if @errors;

		push(@errors, "#ci{kit.subkits} has been superceeded by #ci{kit.features}")
			if $env->defines('kit.subkits');

		my ($env_name, $env_src) = $env->lookup(['genesis.env','params.env']);
		if ($env_name) {
			push(@errors, "#environment name mismatch: #ci{$env_src} specifies #ci{$env_name}")
				unless $env->{name} eq $env_name || in_callback || envset("GENESIS_LEGACY");
		} else {
			push(@errors, "missing required #ci{genesis.env} field")
		}

		# Deprecation Warnings
		if ($env->defines('params.genesis_version_min')) {
			push(@deprecations, "#ci{params.genesis_version_min} has been superceeded by #ci{genesis.min_version}");
			$env->{__params}{genesis}{min_version} = delete($env->{__params}{params}{genesis_version_min});
		}
		if ($env->defines('params.bosh')) {
			push(@deprecations, "#ci{params.bosh} has been superceeded by #ci{genesis.bosh_env}");
			$env->{__params}{genesis}{bosh_env} = delete($env->{__params}{params}{bosh});
		}

		(my $min_version = $env->lookup('genesis.min_version','')) =~ s/^v//i;
		if ($min_version) {
			if ($Genesis::VERSION eq "(development)") {
				push(@config_warnings, "using development version of Genesis, cannot confirm it meets minimum version of #ci{$min_version}");
			} elsif (! new_enough($Genesis::VERSION, $min_version)) {
				push(@errors, "genesis #Ri{v$Genesis::VERSION} does not meet minimum version of #ci{$min_version}");
			}
		}
		$env->{__min_version} = $min_version || '0.0.0';

		my $kit_name = $env->lookup('kit.name');
		my $kit_version = $env->lookup('kit.version');
		my $kit = $env->{top}->local_kit_version($kit_name, $kit_version);
		if ($kit) {
			$env->{kit} = $kit;
			my $overrides = $env->lookup('kit.overrides');
			if (defined($overrides)) {
				$overrides = [ $overrides ] unless (ref($overrides) eq 'ARRAY');
				my @override_files;

				my $i=0;
				my $override_dir = workdir;
				for my $override (@$overrides) {
					my $file="$override_dir/env-overrides-$i.yml";
					$i+=1;
					if (ref($override) eq "HASH") {
						DumpYAML($file,$override);
					} else {
						mkfile_or_fail($file,$override);
					}
					push @override_files, $file;
				}
				$env->kit->apply_env_overrides(@override_files);
			}
		} elsif (!$kit_name) {
			push(@errors, "Missing #ci{kit.name} and no local dev kit");
			push(@errors, "Missing #ci{kit.version}") unless $kit_version;
		} elsif (!$kit_version) {
			push(@errors, "Missing #ci{kit.version}");
		} else {
			push(@errors, sprintf(
				"Unable to locate v%s of #M{%s}` kit for #C{%s} environment.",
				$kit_version, $kit_name, $env->name
			));
		}
		last if @errors;
		$env->kit->check_prereqs($env) or bail "Cannot use the selected kit.";

		if (! $env->kit->feature_compatibility("2.7.0")) {
			push(@errors, sprintf("kit #M{%s} is not compatible with #ci{secrets_mount} feature; check for newer kit version or remove feature.", $env->kit->id))
				if ($env->secrets_mount ne $env->default_secrets_mount);
			push(@errors, sprintf("kit #M{%s} is not compatible with #C{exodus_mount} feature; check for newer kit version or remove feature.", $env->kit->id))
				if ($env->exodus_mount ne $env->default_exodus_mount);
		}
		last;
	}

	unless (under_test && !envset 'GENESIS_TESTING_DEV_VERSION_DETECTION' ) {
		if (@deprecations && !envset("REPORTED_ENV_DEPRECATIONS")) {
			error(
				"#Y{[DEPRECATIONS]} Environment #C{%s} contains the following deprecation:\n  - %s\n",
				$env->{file}, join("\n  - ",map {join("\n    ",split("\n",$_))} @deprecations)
			);
			$ENV{REPORTED_ENV_DEPRECATIONS}=1;
		}
		if (@config_warnings && !envset("REPORTED_ENV_CONFIG_WARNINGS")) {
			error(
				"#Y{[WARNINGS]} Environment #C{%s} contains the following configuration warnings:\n  - %s\n",
				$env->{file}, join("\n  - ",map {join("\n    ",split("\n",$_))} @config_warnings)
			);
			$ENV{REPORTED_ENV_CONFIG_WARNINGS}=1
		}
	}

	bail(
		"#R{[ERROR]} Environment #C{%s} could not be loaded:\n  - %s\n\n".
		"Please fix the above errors and try again.",
		$env->{file}, join("\n  - ",map {join("\n    ",split("\n",$_))} @errors)
	) if @errors;

	return $env
}

# }}}
# from_envvars -- builds a pseudo-env based on the current env vars - used for hooks callbacks {{{
sub from_envvars {
	my ($class,$top) = @_;

	bail "Can only assemble environment from environment variables in a kit hook callback"
		unless ($ENV{GENESIS_KIT_HOOK}||'') eq 'new' && in_callback();

	bug("No 'GENESIS_$_' found in enviornmental variables - cannot assemble environemnt!!")
		for (grep {! $ENV{'GENESIS_'.$_}} qw(ENVIRONMENT KIT_NAME KIT_VERSION ENVIRONMENT_PARAMS));

	my $env = $class->new(name => $ENV{GENESIS_ENVIRONMENT}, top => $top);
	$env->{is_from_envvars} =1;
	$env->{__params} = decode_json($ENV{GENESIS_ENVIRONMENT_PARAMS});

	# reconstitute our kit via top
	my $kit_name = $ENV{GENESIS_KIT_NAME};
	my $kit_version = $ENV{GENESIS_KIT_VERSION};
	$env->{kit} = $env->{top}->local_kit_version($kit_name, $kit_version)
		or bail "Unable to locate v$kit_version of `$kit_name` kit for '$env->{name}' environment.";
	$env->kit->apply_env_overrides(split(' ',$ENV{GENESIS_ENV_KIT_OVERRIDE_FILES}))
	  if defined $ENV{GENESIS_ENV_KIT_OVERRIDE_FILES};

	my $min_version = $ENV{GENESIS_MIN_VERSION} || scalar($env->lookup('genesis.min_version', ''));
	$min_version =~ s/^v//i;

	if ($min_version) {
		if ($Genesis::VERSION eq "(development)") {
			error(
				"#Y{[WARNING]} Environment `$env->{name}` requires Genesis v$min_version or higher.\n".
				"          This version of Genesis is a development version and its feature availability\n".
				"          cannot be verified -- unexpected behaviour may occur.\n"
			) unless (under_test && !envset 'GENESIS_TESTING_DEV_VERSION_DETECTION');
		} elsif (! new_enough($Genesis::VERSION, $min_version)) {
			bail(
				"#R{[ERROR]} Environment `$env->{name}` requires Genesis v$min_version or higher.\n".
				"        You are currently using Genesis v$Genesis::VERSION.\n"
			) unless (under_test && !envset 'GENESIS_TESTING_DEV_VERSION_DETECTION');
		}
	}
	$env->{__min_version} = $min_version || '0.0.0';

	# features
	$env->{'__features'} = [split(' ',$ENV{GENESIS_REQUESTED_FEATURES})]
		if $ENV{GENESIS_REQUESTED_FEATURES};

	# bosh and credhub env overrides
	if (envset 'GENESIS_USE_CREATE_ENV') {
		$env->{__params}{genesis}{use_create_env} = 'true';
		$env->{__params}{genesis}{min_version} ||= $min_version;
		$env->{__bosh} = Genesis::BOSH::CreateEnvProxy->new();
	} else {
		$env->{__bosh} = Genesis::BOSH::Director->from_environment();
	}
	$env->{__params}{genesis}{credhub_env} = $ENV{GENESIS_CREDHUB_EXODUS_SOURCE}
		if ($ENV{GENESIS_CREDHUB_EXODUS_SOURCE});

	# determine our vault and secret path
	for (qw(secrets_mount secrets_base secrets_slug exodus_mount exodus_base ci_mount ci_base root_ca_path)) {
		$env->{'__'.$_} = $env->{__params}{genesis}{$_} = $ENV{'GENESIS_'.uc($_)}
			unless eval "\$env->$_" eq $ENV{'GENESIS_'.uc($_)};
	}

	# Check for v2.7.0 features
	unless ($env->kit->feature_compatibility("2.7.0")) {
		bail("#R{[ERROR]} Kit #M{%s} is not compatible with #C{secrets_mount} feature\n".
		     "        Please upgrade to a newer release or remove params.secrets_mount from #M{%s}",
		     $env->kit->id, $env->{file})
			if ($env->secrets_mount ne $env->default_secrets_mount);
		bail("#R{[ERROR]} Kit #M{%s} is not compatible with #C{exodus_mount} feature\n".
		     "        Please upgrade to a newer release or remove params.exodus_mount from #M{%s}",
		     $env->kit->id, $env->{file})
			if ($env->exodus_mount ne $env->default_exodus_mount);
	}

	bail("\n#R{[ERROR]} No vault specified or configured.")
		unless $env->vault;

	return $env;
}

# }}}
# create - create a new Genesis::Env object from user input {{{
sub create {
	my ($class,%opts) = @_;

	# validate call
	for (qw(name top kit)) {
		bug("No '$_' specified in call to Genesis::Env->create!!")
			unless $opts{$_};
	}

	my $env = $class->new(get_opts(\%opts, qw(name top kit)));
	my $create_env = $opts{'create-env'};

	# environment must not already exist...
	die "Environment file $env->{file} already exists.\n"
		if -f $env->path($env->{file});

	# Setup minimum parameters (normally from the env file) to be able to build
	# the env file.
	$env->{__params} = {
		genesis => {
			env => $opts{name},
			get_opts(\%opts, qw(secrets_path secrets_mount exodus_mount ci_mount root_ca_path credhub_env))}
	};

	# The crazy-intricate create-env/bosh_env dance...
	if ($env->kit->feature_compatibility("2.8.0")) {
		# Kits that are explicitly compatible with 2.8.0 can specify if they
		# support or require create-env deployments.
		my $uce = $env->kit->metadata('use_create_env')||'';
		if ($uce eq 'yes') {
			bail(
				"\n#R{[ERROR]} Kit %s requires use of create-env, but --no-create-env\n        option was specified",
				$env->kit->id
			) if defined($create_env) && !$create_env;
			bail(
				"\n#R{[ERROR]} Cannot specify a bosh environment for environments that use\n".
				"        create-env deployment method"
			) if defined($ENV{GENESIS_BOSH_ENVIRONMENT});
			$env->{__params}{genesis}{use_create_env} = 1;
			$env->{__params}{genesis}{bosh_env} = '';
		} elsif ($uce eq 'no') {
			bail(
				"\n#R{[ERROR]} Kit %s cannot use create-env, but --create-env option\n        was specified",
				$env->kit->id
			) if $create_env;
			$env->{__params}{genesis}{use_create_env} = 0;
			$env->{__params}{genesis}{bosh_env} = $ENV{GENESIS_BOSH_ENVIRONMENT} || $opts{name};
		} else {
			# Complicated state: the kit allows but does not require create-env.
			error(
				"\n#y{[WARNING]} Kit %s supports both bosh and create-env deployment.\n".
				"          No --create-env option specified, so using bosh deployment method.",
				$env->kit->id
			) unless defined($create_env);
			bail(
				"\n#R{[ERROR]} Cannot specify a bosh environment for environments that use\n".
				"        create-env deployment method"
			) if $create_env && defined($ENV{GENESIS_BOSH_ENVIRONMENT});
			$env->{__params}{genesis}{use_create_env} = $create_env || 0;
			$env->{__params}{genesis}{bosh_env} = $create_env ? '' : $ENV{GENESIS_BOSH_ENVIRONMENT} || $opts{name};
		}
	} else {
		bail(
			"\n#R{[ERROR]} Kit %s does not support the --[no-]create-env option",
			$env->kit->id
		) if defined($create_env);
		if ($env->is_bosh_director()) { # Prior to 2.8.0, only the bosh kit can use create_env.
			if ($ENV{GENESIS_BOSH_ENVIRONMENT}) {
				$env->{__params}{genesis}{use_create_env} = 0;
				$env->{__params}{genesis}{bosh_env} = $ENV{GENESIS_BOSH_ENVIRONMENT};
			} else {
				$env->{__params}{genesis}{use_create_env} = 1;
				$env->{__params}{genesis}{bosh_env} = '';
			}
		} else {
			$env->{__params}{genesis}{use_create_env} = 0;
			$env->{__params}{genesis}{bosh_env} = $ENV{GENESIS_BOSH_ENVIRONMENT} || $opts{name};
		}
	}

	# target vault and remove secrets that may already exist
	bail("\n#R{[ERROR]} No vault specified or configured.")
		unless $env->vault;

	# TODO: Remove credhub secrets
	if (! $env->kit->uses_credhub) {
		$env->remove_secrets(all => 1) || bail "Cannot continue with existing secrets for this environment";
	}

	# credhub env overrides
	$env->{__params}{genesis}{credhub_env} = $ENV{GENESIS_CREDHUB_EXODUS_SOURCE}
		if ($ENV{GENESIS_CREDHUB_EXODUS_SOURCE});

	## initialize the environment
	$env->download_required_configs('new')
		unless $env->lookup('genesis.use_create_env','0');

	if ($env->has_hook('new')) {
		$env->run_hook('new');
	} else {
		bail(
			"#R{[ERROR]} Kit %s is not supported in Genesis %s (no hooks/new script).\n".
			"        Check for a newer version of this kit.",
			$env->kit->id, $Genesis::VERSION
		);
	}

	# Load the environment from the file to pick up hierarchy, and generate secrets
	$env = $class->load(name =>$env->name, top => $env->top);
	if (! $env->kit->uses_credhub) {
		if (! $env->add_secrets(verbose=>1)) {
			$env->remove_secrets(all => 1, 'no-prompt' => 1);
			unlink $env->file;
			return undef;
		}
	}
	return $env;
}

# }}}
# exists - returns true if the given environment exists {{{
sub exists {
	my ($ref,%args) = @_;
	unless (ref($ref)) {
		# called on the class, need a instance
		return undef if _env_name_errors($args{name});
		eval{ $ref = $ref->new(%args) };
		bug ("Failed to check existence of Genesis Environment: %s", $@) if $@;
		return undef unless $ref;
	}
	return -f $ref->path($ref->{file});
}

#}}}
#}}}

### Private Class Methods {{{

# _env_name_errors - ensure name is valid {{{
sub _env_name_errors {
	my ($name) = @_;

	my @errors = ();

	bug("Environment name expected to be a string, got a ", ref($name) || 'undefined value')
		if !defined($name) || ref($name);

	push(@errors,"names must not be empty.\n")
		if !$name;

	push(@errors,"names must not contain whitespace.\n")
		if $name =~ m/\s/;

	push(@errors,"names can only contain lowercase letters, numbers, and hyphens.\n")
		if $name !~ m/^[a-z0-9_-]+$/;

	push(@errors,"names must start with a (lowercase) letter.\n")
		if $name !~ m/^[a-z]/;

	push(@errors,"names must not end with a hyphen.\n")
		if $name =~ m/-$/;

	push(@errors,"names must not contain sequential hyphens (i.e. '--').\n")
		if $name =~ m/--/;

	return '' unless scalar(@errors);
	return join("\n  - ", '', @errors);
}

# }}}
# }}}

### Instance Methods {{{

# Public Accessors: name, file, kit, top {{{
sub name   { $_[0]->{name};   }
sub file   { $_[0]->{file};   }
sub kit    { $_[0]->{kit}    || bug("Incompletely initialized environment '".$_[0]->name."': no kit specified"); }
sub top    { $_[0]->{top}    || bug("Incompletely initialized environment '".$_[0]->name."': no top specified"); }

# }}}
# Delegations: type, vault, path {{{
sub type   { $_[0]->top->type; }
sub vault  { $_[0]->top->vault; }
sub path   { shift->top->path(@_); }
# }}}

# Information Lookup
# deployment_name - returns the deployment name (env name + env type) {{{
sub deployment_name {
	$_[0]->_memoize('__deployment', sub {
		my $self = shift;
		sprintf('%s-%s',$self->name,$self->top->type);
	});
}

# }}}
# is_bosh_director - returns true if the environment represents a BOSH director deployment {{{
sub is_bosh_director {
	my $self = shift;
	$self->kit->id =~ /^bosh\// || $self->kit->metadata->{is_bosh_director};
	# TODO: This is very fragile, rework for better diagnosis
}

# }}}
# use_create_env - true if the deployment uses bosh create-env {{{
sub use_create_env {

	return 'unknown' if $_[0]->_get_memo() && $_[0]->_get_memo() eq "processing";
	return $_[0]->_memoize(sub {
		my ($self) = @_;
		$self->_set_memo("processing");
		my $is_bosh_director = $self->is_bosh_director;

		sub clear_and_bail {
			my $self = shift;
			$self->_clear_memo('__use_create_env');
			bail(@_);
		}

		sub validate_create_env_state {
			my ($self,$is_create_env,$has_bosh_env,$kit_name,$is_bosh_kit) = @_;
			clear_and_bail($self,
				"\n#R{[ERROR]} This #M{$kit_name} environment specifies an alternative bosh_env, but is\n".
				"        marked as a create-env (proto) environment. Create-env deployments can't\n".
				"        use a #C{genesis.bosh_env} value, so please remove it, or mark this\n".
				"        environment as a non-create-env environment.  It may be that bosh_env is\n".
				"        configured in an inherited environment file."
			) if $is_create_env && $has_bosh_env;
			clear_and_bail($self,
				"\n#R{[ERROR]} This #M{$kit_name} environment does not use create-env (proto) or specify\n".
				"        an alternative #C{genesis.bosh_env} as a deploy target. Please provide\n".
				"        the name of the BOSH environment that will deploy this environment, or\n".
				"        mark this environment as a create-env environment."
			) unless $is_create_env || $has_bosh_env || !$is_bosh_kit;
		}

		my $different_bosh_env = $self->bosh_env && $self->bosh_env ne '--' && ($self->bosh_env ne $self->name);

		if ($self->kit->feature_compatibility("2.8.0")) {
			# Kits that are explicitly compatible with 2.8.0 can specify if they
			# support or require create-env deployments.

			my $kuce = $self->kit->metadata('use_create_env')||'';
			if ($kuce eq 'yes') {
				clear_and_bail($self,
					"\n#R{[ERROR]} This kit only allows create-env deployments, but this environment\n".
					"        specifies an alternative bosh_env.  Please remove the #C{genesis.bosh_env}\n".
					"        entry from the environment file."
				) if $different_bosh_env;
				return 1;
			};
			if ($kuce eq 'no') {
				clear_and_bail($self,
					"\n#R{[ERROR]} BOSH environments must specify the name of the parent BOSH director\n".
					"        that will deploy this enviornment under #C{genesis.bosh_env} in the\n".
					"        file, because unlike other kits, it cannot derive its director from its\n".
					"        environment name."
				) if $is_bosh_director && !$different_bosh_env;
				return 0 ;
			}

			my $euce = $self->lookup('genesis.use_create_env', undef);
			my $is_create_env = (
				$euce || (
					! defined($euce) && $self->kit->id =~ /^bosh\// && grep {$_ eq 'proto' || $_ eq '+ocfp-mngt'} $self->features
			)) ? 1 : 0;

			validate_create_env_state($self,$is_create_env,$different_bosh_env,$self->kit->{name},$is_bosh_director);
			return $is_create_env;
		}

		# Before 2.8.0, we only support create-env deployments for bosh deployments.
		return 0 unless $is_bosh_director;

		# If creating a new bosh environment, we need to do some special handling.

		# Support pre-v2.8.0 create env schemes...
		my $euce;
		if ($self->exists) {
			my $features = scalar($self->lookup(['kit.features', 'kit.subkits'], []));
			$euce = scalar(grep {$_ =~ /^(proto|bosh-init|create-env)$/} @$features) ? 1 : 0;
		} else {
			$euce = !$ENV{GENESIS_BOSH_ENVIRONMENT};
		}
		dump_var detected=>$euce, diff => $different_bosh_env;
		validate_create_env_state($self,$euce,$different_bosh_env,"bosh",1);
		return $euce;
	});
}

# }}}
# feature_compatibility - returns true if the min version for the environment meets or exceeds the specified version {{{
sub feature_compatibility {
	my ($self,$version) = @_;
	trace("Comparing %s environment specified version (%s) to %s feature base", $self->name, $self->{__min_version}, $version);
	return new_enough($self->{__min_version},$version);
}

# }}}
# tmppath - provide the path to the temporary file storage for this envionment {{{
sub tmppath {
	my ($self, $relative) = @_;
	return $relative ? "$self->{__tmp}/$relative"
	                 :  $self->{__tmp};
}

# }}}
# potential_environment_files - list the heirarchal environment files possible for this env {{{
sub potential_environment_files {
	my $env = $ENV{PREVIOUS_ENV} || ''; # ci pipelines need to pull cache for previous envs
	return $_[0]->relate($env, ".genesis/cached/$env");
}

# }}}
# actual_environment_files - list the heirarchal environment files that exist for this env {{{
sub actual_environment_files {
	my $ref = $_[0]->_memoize('__actual_files', sub {
		my $self = shift;
		my @files;
		for my $file (grep {-f $self->path($_)} $self->potential_environment_files) {
			push( @files, $self->_genesis_inherits($file, @files),$file);
		};
		return \@files;
	});
	return @$ref;
}

# }}}
# relate - get hierarchal file relationships with another environment {{{
sub relate {
	my ($self, $them, $common_base, $unique_base) = @_;
	return relate_by_name($self->{name}, ref($them) ? $them->{name} : $them, $common_base, $unique_base);
}

# }}}
# relate_by_name - get hierarchal file relationships between named environments {{{
sub relate_by_name {
	my ($name, $other, $common_base, $unique_base) = @_;
	$common_base ||= '.';
	$unique_base ||= '.';
	$other ||= '';

	my @a = split /-/, $name;
	my @b = split /-/, $other;
	my @c = (); # common

	while (@a and @b) {
		last unless $a[0] eq $b[0];
		push @c, shift @a; shift @b;
	}
	# now @c contains common tokens (us, west, 1)
	# and @a contains unique tokens (preprod, a)

	my (@acc, @common, @unique);
	for (@c) {
		# accumulate tokens: (us, us-west, us-west-1)
		push @acc, $_;
		push @common, "$common_base/".join('-', @acc).".yml";
	}
	for (@a) {
		# accumulate tokens: (us-west-1-preprod,
		#                     us-west-1-preprod-a)
		push @acc, $_;
		push @unique, "$unique_base/".join('-', @acc).".yml";
	}

	trace("[env $name] in relate(): common $_") for @common;
	trace("[env $name] in relate(): unique $_") for @unique;

	return wantarray
		? (@common, @unique)
		: { common => \@common, unique => \@unique };
}

# }}}
# format_yaml_files - return the list of all yaml files used to create the manifest {{{
sub format_yaml_files {
	my ($self, %options) = @_;
	my $local_label = $options{'local-label'} || "./";
	my $padding = $options{padding} || '';

	my @files;
	if ($options{'include-kit'}) {
		my $kit_label   = $options{'kit-label'} || "#G{".$self->kit->id.":} ";
		$local_label = sprintf("%*s", length($kit_label), "#C{local:} ");
		my $env_path = $self->path();
		for ($self->kit_files) {
			if ($_ =~ qr/^$env_path\/(.*)$/) {
				push @files, "$padding$local_label$1";
			} else {
				push @files, "$padding$kit_label#K{$_}";
			}
		}
	}
	push @files, map {(my $f = $_) =~ s/^\.\//$padding$local_label/; $f}
		($self->actual_environment_files);
	return @files;
}

# }}}
# features - returns the list of features (specified and derived) {{{
sub features {
	my $ref = $_[0]->_memoize(sub {
		my $self = shift;
		my $features = scalar($self->lookup('kit.features', []));
		bail(
			"#R{[ERROR]} Environment #C{%s} #G{kit.features} must be an array - got a #y{%s}.\n",
			$self->name, defined($features) ? (lc(ref($features)) || 'string') : 'null'
		) unless ref($features) eq 'ARRAY';

		my @derived_features = grep {$_ =~ /^\+/} $features;
		bail(
			"#R{[ERROR]} Environment #C{%s} cannot explicitly specify derived features:\n  - %s",
			$self->name, join("\n  - ",@derived_features)
		) if @derived_features;
		$features = [$self->kit->run_hook('features',env => $self, features => $features)]
			if $self->kit->has_hook('features');
		$features;
	});
	return @$ref;
}

# }}}
# has_feature - returns true if the environment requests the given feature {{{
sub has_feature {
	my ($self, $feature) = @_;
	for my $have ($self->features) {
		return 1 if $feature eq $have;
	}
	return 0;
}

# }}}
# params - get all the values from the hierarchal environment. {{{
sub params {
	my $ref = $_[0]->_memoize(sub {
		my ($self) = @_;
		debug("running spruce merge of environment files, without evaluation, to find parameters");
		my @merge_files = map { $self->path($_) } $self->actual_environment_files();

		my ($out, $rc, $err);
		if (envset("GENESIS_UNEVALED_PARAMS")) {
			pushd $self->path;
			$out = run({ onfailure => "Unable to merge $self->{name} environment files", stderr => undef },
			'spruce merge --multi-doc --skip-eval "$@" | spruce json', @merge_files);
			popd;
		} else {
			my $env = {
				%{$self->vault->env()},               # specify correct vault for spruce to target
				REDACT => ''
			};
			$out = $self->adaptive_merge({json => 1, env => $env}, @merge_files);
		}
		load_json($out);
	});
	return $ref;
}

# }}}
# defines - true if the given path is defined in the hierarchal environment parameters. {{{
sub defines {
	my ($self, $key) = @_;
	my (undef, $found) = struct_lookup($self->params(),$key);
	return defined($found);
}

# }}}
# lookup - look up a value from the heirarchal evironment {{{
sub lookup {
	my ($self, $key, $default) = @_;
	return struct_lookup($self->params, $key, $default);
}

# }}}
# partial_manifest_lookup - look up a value from a best-effort merged manifest for this environment {{{
sub partial_manifest_lookup {
	my ($self, $key, $default) = @_;
	my ($partial_manifest, undef) = $self-> _manifest(partial=>1,no_warnings=>1);
	return struct_lookup($partial_manifest, $key, $default);
}

# }}}
# manifest_lookup - look up a value from a completely merged manifest for this environment {{{
sub manifest_lookup {
	my ($self, $key, $default) = @_;
	my ($manifest, undef) = $self->_manifest(redact => 0);
	return struct_lookup($manifest, $key, $default);
}

# }}}
# last_deployed_lookup - look up values from the last deployment of this environment {{{
sub last_deployed_lookup {
	my ($self, $key, $default) = @_;
	my $last_deployment = $self->path(".genesis/manifests/".$self->{name}.".yml");
	die "No successfully deployed manifest found for $self->{name} environment"
		unless -e $last_deployment;
	my $out = run(
		{ onfailure => "Could not read last deployed manifest for $self->{name}" },
		'spruce json $1', $last_deployment);
	my $manifest = load_json($out);
	return struct_lookup($manifest, $key, $default);
}

# }}}
# exodus_lookup - lookup Exodus data from the last deployment of this (or named) deployment {{{
sub exodus_lookup {
	my ($self, $key, $default,$for) = @_;
	$for ||= $self->exodus_slug;
	my $path =  $self->exodus_mount().$for;
	debug "Checking if $path path exists...";
	return $default unless $self->vault->has($path);
	debug "Exodus data exists, retrieving it and converting to json";
	my $out;
	eval {$out = $self->vault->get($path);};
	bail "Could not get $for exodus data from the Vault: $@" if $@;

	my $exodus = _unflatten($out);
	return struct_lookup($exodus, $key, $default);
}

# }}}
# dereferenced_kit_metadata - get kit metadata that been filled with environment references {{{
sub dereferenced_kit_metadata {
	my ($self) = shift;
	return $self->kit->dereferenced_metadata(sub {$self->partial_manifest_lookup(@_)}, 1);
}

# }}}
# adaptive_merge - merge as much as possible, deferring anything unmergible {{{
sub adaptive_merge {
	my ($self, @files) = @_;
	pushd $self->path;
	my %opts = ref($files[0]) eq 'HASH' ? %{shift @files} : ();
	my $json = !!delete($opts{json});
	my ($out,$rc,$err) = run({stderr=>0, %opts}, 'spruce merge --multi-doc --go-patch "$@"', @files);
	my $orig_errors;
	if ($rc) {
		$orig_errors = join("\n", grep {$_ !~ /^\s*$/} lines($err));
		my $contents = '';
		for my $content (map {slurp($_)} @files) {
			$contents .= "\n" unless substr($contents,-1,1) eq "\n";
			$contents .= "---\n" unless substr($content,0,3) eq "---";
			$contents .= $content;
		}
		my $uneval = read_json_from(run(
			{ onfailure => "Unable to merge files without evaluation", stderr => undef, %opts },
			'spruce merge --multi-doc --go-patch --skip-eval "$@" | spruce json', @files
		));

		my $attempt=0;
		while ($attempt++ < 5 and $rc) {
			my @errs = map {$_ =~ /^ - \$\.([^:]*): (.*)$/; [$1,$2]} grep {/^ - \$\./} lines($err);
			for my $err_details (@errs) {
				my ($err_path, $err_msg) = @{$err_details};
				my $val = struct_lookup($uneval, $err_path);
				my $orig_err_path = $err_path;
				WANDER: while (! $val) {
					trace "[adaptive_merge] Couldn't find direct dereference error, backtracing $err_path";
					bug "Internal error: Could not find line causing error '$err_msg' during adaptive merge."
						unless $err_path =~ s/.[^\.]+$//;
					$val = struct_lookup($uneval, $err_path) || next;
					if (ref($val) eq "HASH") {
						for my $sub_key (keys %$val) {
							if ($val->{$sub_key} && $val->{$sub_key} =~ /\(\( *inject +([^\( ]*) *\)\)/) {
								$err_path = $1;
								trace "[adaptive_merge] Found inject on $sub_key, redirecting to $err_path";
								$val = struct_lookup($uneval, $err_path);
								next WANDER;
							}
						}
					}
					$val = undef; # wasn't what we were looking for, look deeper...
				}

				my $spruce_ops=join("|", qw/
					calc cartesian-product concat defer empty file grab inject ips join
					keys load param prune shuffle sort static_ips vault awsparam
					awssecret base64
					/);
				(my $replacement = $val) =~ s/\(\( *($spruce_ops) /(( defer $1 /;
				trace "[adaptive_merge] Resolving $orig_err_path" . ($err_path ne $orig_err_path ? (" => ". $err_path) : "");
				$contents =~ s/\Q$val\E/$replacement/sg;
			}
			my $premerge = mkfile_or_fail($self->tmppath('premerge.yml'),$contents);
			($out,$rc,$err) = run({stderr => 0, %opts }, 'spruce merge --multi-doc --go-patch "$1"', $premerge);
		}

		bail(
			"Could not merge $self->{name} environment files:\n\n".
			"$err\n\n".
			"Efforts were made to work around resolving the following errors, but if\n".
			"they caused the above errors, you may be able to partially resolve this\n".
			"issue by using #C{export GENESIS_UNEVALED_PARAMS=1}:\n\n".
			$orig_errors
		) if $rc;
	}
	if ($json) {
		my $postmerge = mkfile_or_fail($self->tmppath("postmerge.yml"),$out);
		$out = run({onfailure => "Unable to read json from merged $self->{name} environment files"},
			'spruce json "$1"', $postmerge
		);
	}
	popd;
	return wantarray ? ($out,$orig_errors) : $out;
}

# }}}

# Environment Variables
# get_environment_variables - returns a hash of all environment variables pertaining to this Genesis::Env object {{{
sub get_environment_variables {
	my ($self, $hook) = @_;

	my %env;

	my $is_alt_path = defined($ENV{GENESIS_CALLER_DIR}) && $self->path ne $ENV{GENESIS_CALLER_DIR};

	$env{GENESIS_ROOT}         = $self->path;
	$env{GENESIS_ENVIRONMENT}  = $self->name;
	$env{GENESIS_TYPE}         = $self->type;
	$env{GENESIS_CALL_BIN}     = humanize_bin();

	# Deprecated, use GENESIS_CALL_ENV instead, but drop the $GENESIS_ENVIRONMENT after the command
	$env{GENESIS_CALL}         = $env{GENESIS_CALL_BIN}.
	                            ($is_alt_path ? sprintf(" -C '%s'", humanize_path($self->path)) : "");

	# Require from the main module
	%::GENESIS_COMMANDS = () unless keys(%::GENESIS_COMMANDS);
	my @known_cmds = keys(%::GENESIS_COMMANDS);

	my $env_ref = $self->name;
	$env_ref .= '.yml' if (grep {$_ eq $self->name} @known_cmds);
	$env_ref = humanize_path($self->path)."/$env_ref" if $is_alt_path;
	$env_ref = "'$env_ref'" if $env_ref =~ / \(\)!\*\?/;

	$env{GENESIS_ENV_REF}  = $env_ref;
	$env{GENESIS_CALL_ENV} = "$env{GENESIS_CALL_BIN} $env_ref";

	if ($ENV{GENESIS_COMMAND}) {
		$env{GENESIS_PREFIX_TYPE} = $ENV{GENESIS_PREFIX_TYPE} || 'none';
		$env{GENESIS_CALL_PREFIX} = sprintf("%s %s %s", $env{GENESIS_CALL_BIN}, $env_ref, $ENV{GENESIS_COMMAND});
		$env{GENESIS_CALL_FULL} = $env{GENESIS_PREFIX_TYPE} =~ /file$/
			? $env{GENESIS_CALL_PREFIX}
			: sprintf("%s %s '%s'", $env{GENESIS_CALL},$ENV{GENESIS_COMMAND}, $self->name);
	}

	# Full param json to reconstitution by from_envvars method.
	$env{GENESIS_ENVIRONMENT_PARAMS} = encode_json($self->params);

	# Genesis minimum version (if specified)
	my $min_version = $self->lookup('genesis.min_version');
	$env{GENESIS_MIN_VERSION} = $min_version if $min_version;

	# Vault ENV VARS
	$env{GENESIS_TARGET_VAULT} = $env{SAFE_TARGET} = $self->vault->ref;
	$env{GENESIS_VERIFY_VAULT} = $self->vault->connect_and_validate->verify || "";

	# Kit ENV VARS
	$env{GENESIS_KIT_NAME}               = $self->kit->name;
	$env{GENESIS_KIT_VERSION}            = $self->kit->version;
	$env{GENESIS_ENV_KIT_OVERRIDE_FILES} = join(' ', $self->kit->env_override_files);

	# Genesis v2.7.0 Secrets management
	# This provides GENESIS_{SECRETS,EXODUS,CI}_{MOUNT,BASE}
	# as well as GENESIS_{SECRETS,EXODUS,CI}_MOUNT_OVERRIDE
	for my $target (qw/secrets exodus ci/) {
		for my $target_type (qw/mount base/) {
			my $method = "${target}_${target_type}";
			$env{uc("GENESIS_${target}_${target_type}")} = $self->$method();
		}
		my $method = "${target}_mount";
		my $default_method = "default_$method";
		$env{uc("GENESIS_${target}_MOUNT_OVERRIDE")} = ($self->$method ne $self->$default_method) ? "true" : "";
	}
	$env{GENESIS_VAULT_PREFIX} = # deprecated in v2.7.0
	$env{GENESIS_SECRETS_PATH} = # deprecated in v2.7.0
	$env{GENESIS_SECRETS_SLUG} = $self->secrets_slug;
	$env{GENESIS_SECRETS_SLUG_OVERRIDE} = $self->secrets_slug ne $self->default_secrets_slug ? "true" : "";
	$env{GENESIS_ROOT_CA_PATH} = $self->root_ca_path;

	unless (grep { $_ eq ($hook||'') } qw/new features/) {
		$env{GENESIS_REQUESTED_FEATURES} = join(' ', $self->features);
	}

	# Credhub support
	my %credhub_env = $self->credhub_connection_env;
	$env{$_} = $credhub_env{$_} for keys %credhub_env;

	# BOSH support
	if ($self->use_create_env) {
		$env{GENESIS_USE_CREATE_ENV} = $self->use_create_env eq 'unknown' ? 'unknown' : 'true';
		for my $bosh_env (qw/ALIAS ENVIRONMENT CA_CERT CLIENT CLIENT_SECRET DEPLOYMENT/) {
			$env{"BOSH_$bosh_env"}=undef; # clear out any bosh variables
		}
	} else {
		$env{GENESIS_USE_CREATE_ENV} = "false";
		$env{BOSH_ALIAS} = $self->bosh_env;
		if ($self->{__bosh} || grep {$_ eq 'bosh'} ($self->kit->required_connectivity($hook))) {
			my %bosh_env = $self->bosh->environment_variables;
			$env{$_} = $bosh_env{$_} for keys %bosh_env;
		}
	}

	return %env
}

# }}}
# credhub_connection_env - returns environment variables hash for connecting to this environment's Credhub {{{
sub credhub_connection_env {
	my $self = shift;
	my ($credhub_src,$credhub_src_key) = $self->lookup(
		['genesis.credhub_env','genesis.bosh_env','params.bosh','genesis.env','params.env']
	);
	my %env=();

	my $credhub_path = $credhub_src;
	$env{GENESIS_CREDHUB_EXODUS_SOURCE_OVERRIDE} =
		(($credhub_src_key || "") eq 'genesis.credhub_env') ? $credhub_src : "";

	if ($credhub_src =~ /\/\w+$/) {
		$credhub_path  =~ s/\/([^\/]*)$/-$1/;
	} else {
		$credhub_src .= "/bosh";
		$credhub_path .= "-bosh";
	}
	$env{GENESIS_CREDHUB_EXODUS_SOURCE} = $credhub_src;
	$env{GENESIS_CREDHUB_ROOT}=sprintf("%s/%s-%s", $credhub_path, $self->name, $self->type);

	if ($credhub_src) {
		my $credhub_info = $self->exodus_lookup('.',undef,$credhub_src);
		if ($credhub_info) {
			$env{CREDHUB_SERVER} = $credhub_info->{credhub_url}||"";
			$env{CREDHUB_CLIENT} = $credhub_info->{credhub_username}||"";
			$env{CREDHUB_SECRET} = $credhub_info->{credhub_password}||"";
			$env{CREDHUB_CA_CERT} = sprintf("%s%s",$credhub_info->{ca_cert}||"",$credhub_info->{credhub_ca_cert}||"");
		}
	}

	return %env;
}

# }}}

# Environment Dependencies
# connect_required_endpoints - ensure external dependencies are reachable {{{
sub connect_required_endpoints {
	my ($self, @hooks) = @_;
	my @endpoints;
	push(@endpoints, $self->kit->required_connectivity($_)) for (@hooks);
	for (uniq(@endpoints)) {
		$self->with_vault   if $_ eq 'vault';
		$self->with_bosh    if $_ eq 'bosh';
		$self->with_credhub if $_ eq 'credhub'; # TODO: write this...!
		bail("#R{[ERROR]} Unknown connectivity endpoint type #Y{%s} in kit #m{%s}", $_, $self->kit->id);
	}
	return $self
}

# }}}

# Environment Dependencies - Vault
# with_vault - ensure this environment is able to connect to the Vault server {{{
sub with_vault {
	my $self = shift;
	$ENV{GENESIS_SECRETS_MOUNT} = $self->secrets_mount();
	$ENV{GENESIS_EXODUS_MOUNT} = $self->exodus_mount();
	bail("\n#R{[ERROR]} No vault specified or configured.")
		unless $self->vault;
	return $self;
}

# }}}
# root_ca_path - returns the root_ca_path, if provided by the environment file (env: GENESIS_ROOT_CA_PATH) {{{
sub root_ca_path {
	my $self = shift;
	unless (exists($self->{__root_ca_path})) {
		$self->{__root_ca_path} = $self->lookup('genesis.root_ca_path','');
		$self->{__root_ca_path} =~ s/\/$// if $self->{__root_ca_path};
	}

	return $self->{__root_ca_path};
}

# }}}
# secrets_mount - returns the Vault path under which all secrets are stored (env: GENESIS_SECRETS_MOUNT) {{{
sub default_secrets_mount { '/secret/'; }
sub secrets_mount {
	$_[0]->_memoize(sub{
		(my $mount = $_[0]->lookup('genesis.secrets_mount', $_[0]->default_secrets_mount)) =~ s#^/?(.*?)/?$#/$1/#;
		return $mount
	});
}

# }}}
# secrets_slug - returns the component of the Vault path under the mount that represents this environment (env: GENESIS_SECRETS_SLUG) {{{
sub default_secrets_slug {
	(my $p = $_[0]->name) =~ s|-|/|g;
	return $p."/".$_[0]->top->type;
}
sub secrets_slug {
	$_[0]->_memoize(sub {
		my $slug = $_[0]->lookup(
			['genesis.secrets_path','params.vault_prefix','params.vault'],
			$_[0]->default_secrets_slug
		);
		$slug =~ s#^/?(.*?)/?$#$1#;
		return $slug
	});
}

# }}}
# secrets_base - returns the full Vault path for secrets stored for this environment with / suffic (env: GENESIS_SECRETS_BASE) {{{
sub secrets_base {
	$_[0]->_memoize(sub {
		$_[0]->secrets_mount . $_[0]->secrets_slug . '/'
	});
}

# }}}
# exodus_mount - returns the Vault path under which all Exodus data is stored (env: GENESIS_EXODUS_MOUNT) {{{
sub default_exodus_mount { $_[0]->secrets_mount . 'exodus/'; }
sub exodus_mount {
	$_[0]->_memoize(sub {
		(my $mount = $_[0]->lookup('genesis.exodus_mount', $_[0]->default_exodus_mount)) =~ s#^/?(.*?)/?$#/$1/#;
		return $mount;
	});
}

# }}}
# exodus_slug - returns the component of the Vault path under the Exodus mount for this evironments Exodus data {{{
sub exodus_slug {
	sprintf("%s/%s", $_[0]->name, $_[0]->type);
}

# }}}
# exodus_base - returns the full Vault path of the Exodus data for this environment (env:  GENESIS_EXODUS_BASE) {{{
sub exodus_base {
	$_[0]->_memoize(sub {
		$_[0]->exodus_mount . $_[0]->exodus_slug
	});
}

# }}}
# ci_mount - returns the Vault path under which all CI secrets are stored (env: GENESIS_CI_MOUNT) {{{
sub default_ci_mount { $_[0]->secrets_mount . 'ci/'; }
sub ci_mount {
	$_[0]->_memoize(sub {
		(my $mount = $_[0]->lookup('genesis.ci_mount', $_[0]->default_ci_mount)) =~ s#^/?(.*?)/?$#/$1/#;
		return $mount;
	});
}

# }}}
# ci_base - returns the full Vault path under which the CI secrets for this environment are stored (env: GENESIS_CI_BASE) {{{
sub ci_base {
	$_[0]->_memoize(sub {
		my $default = sprintf("%s%s/%s/", $_[0]->ci_mount, $_[0]->type, $_[0]->name);
		(my $base = $_[0]->lookup('genesis.ci_base', $default)) =~ s#^/?(.*?)/?$#/$1/#;
		return $base
	});
}

# }}}

# Environment Dependencies - BOSH and BOSH Config Files
# with_bosh - ensure the BOSH director is available and authenticated {{{
sub with_bosh {
	$_[0]->bosh->connect_and_validate;
	$_[0];
}

# }}}
# bosh_env - return the bosh_env for this environment {{{
sub bosh_env {
	my $self = shift;
	my $env_bosh_target = scalar($self->lookup('genesis.bosh_env', $self->is_bosh_director ? undef : $self->{name}));
  # TODO? warn if GENESIS_BOSH_ENVIRONMENT is set and different
}

# }}}
# bosh - the Genesis::BOSH::Director (or ::CreateEnvProxy) associated with this environment {{{
sub bosh {
	scalar $_[0]->_memoize(sub {
		my $self = shift;
		my $bosh;
		return Genesis::BOSH::CreateEnvProxy->new($self) if $self->use_create_env;

		# If we're in a callback or under test, just reload from envirionemnt variables.
		if (in_callback || under_test) {
			if ($ENV{GENESIS_BOSH_ENVIRONMENT} && $ENV{BOSH_CLIENT} && is_valid_uri($ENV{GENESIS_BOSH_ENVIRONMENT})) {
				$ENV{BOSH_ENVIRONMENT} = $ENV{GENESIS_BOSH_ENVIRONMENT};
				$ENV{BOSH_ALIAS} ||= scalar($self->lookup('genesis.bosh_env', $self->{name}));
				$ENV{BOSH_DEPLOYMENT} ||= $self->deployment_name;
				$bosh = Genesis::BOSH::Director->from_environment();
				return $bosh if $bosh;
			}
		}

		# bosh env can be <alias>[/<deployment-type>]@[http(s?)://<host>[:<port>]/][<mount>]
		my ($bosh_alias,$bosh_dep_type,$bosh_exodus_vault,$bosh_exodus_mount) = $self->_parse_bosh_env();

		my $bosh_vault = $self->vault;
		if ($bosh_exodus_vault) {
			$bosh_vault = Genesis::Vault->find_single_match_or_bail($bosh_exodus_vault);
			bail(
				"#R{[ERROR]} Could not access vault #C{$bosh_exodus_vault} to retrieve BOSH director\n".
				"        login credentials"
			) unless $bosh_vault && $bosh_vault->connect_and_validate;
		}

		$bosh = Genesis::BOSH::Director->from_exodus(
			$bosh_alias,
			vault => $bosh_vault,
			exodus_mount => $bosh_exodus_mount || $self->exodus_mount,
			bosh_deployment_type => $bosh_dep_type,
			deployment => $self->deployment_name,
		) || Genesis::BOSH::Director->from_alias(
			$bosh_alias,
			deployment => $self->deployment_name
		);
		bail("#R{[ERROR]} Could not find BOSH director #M{%s}", $bosh_alias)
			unless $bosh;

		error(
			"#Y{[WARNING]} Calling shell has BOSH_ALIAS set to %s, but this environment\n".
			"          specifies the #M{%s} BOSH director; ignoring \$BOSH_ALIAS set in shell",
			$ENV{BOSH_ALIAS}, $bosh->alias
		) if ($ENV{BOSH_ALIAS} && $ENV{BOSH_ALIAS} ne $bosh->{alias});

		if ($ENV{BOSH_ENVIRONMENT}) {
			if (is_valid_uri($ENV{BOSH_ENVIRONMENT})) {
				error(
					"#Y{[WARNING]} Calling shell has BOSH_ENVIRONMENT set to %s, but this environment\n".
					"          specifies the BOSH director at #M{%s};\n".
					"          ignoring \$BOSH_ENVIRONMENT set in shell",
					$ENV{BOSH_ENVIRONMENT}, $bosh->url
				) if ($ENV{BOSH_ENVIRONMENT} ne $bosh->url);
			} else {
				error(
					"#Y{[WARNING]} Calling shell has BOSH_ENVIRONMENT set to %s, but this environment\n".
					"          specifies the #M{%s} BOSH director; ignoring \$BOSH_ENVIRONMENT set in shell",
					$ENV{BOSH_ENVIRONMENT}, $bosh->alias
				) if ($ENV{BOSH_ENVIRONMENT} ne $bosh->alias);
			}
		}

		return $bosh;
	});
}

#}}}

# Config Management
# configs - return the list of configs being used by this environment. {{{
sub configs {
	my @env_configs = map {
		$_ =~ m/GENESIS_([A-Z0-9_-]+)_CONFIG(?:_(.*))?$/;
		lc($1).($2 && $2 ne '*' ? "\@$2" : '');
	} grep {
		/GENESIS_[A-Z0-9_-]+_CONFIG(_.*)?$/;
	} keys %ENV;
	my @configs = sort(uniq(keys %{$_[0]->{__configs}}, @env_configs));
	return @configs # can't just return the above because scalar/list context crazies
}

# }}}
# required_configs - determine what BOSH configs are needed {{{
sub required_configs {
	my ($self, @hooks) = @_;
	return () if $self->use_create_env;
	my @deploy_hooks = $self->_memoize('__deploy_hooks', sub {
		my $self = shift;
		my @h = qw/blueprint check manifest/;
		push @h, grep {$self->kit->has_hook($_)} qw(pre-deploy post-deploy);
	});
	my @expanded_hooks;
	push(@expanded_hooks, ($_ eq 'deploy' ? @deploy_hooks : $_)) for (@hooks);
	return $self->kit->required_configs(uniq(@expanded_hooks));
}

# }}}
# missing_required_configs - determine what BOSH configs are missing {{{
sub missing_required_configs {
	my ($self, @hooks) = @_;
	return grep {!$self->has_config($_)} $self->required_configs(@hooks);
}

# }}}
# has_required_configs - determine what BOSH configs are needed {{{
sub has_required_configs {
	my ($self, @hooks) = @_;
	return scalar($self->missing_required_configs(@hooks)) == 0;
}

# }}}
# download_required_configs - determzoine what BOSH configs are needed and download them {{{
sub download_required_configs {
	my ($self, @hooks) = @_;
	my @configs = $self->missing_required_configs(@hooks);
	$self->with_bosh->download_configs(@configs) if @configs;
	return $self
}

# }}}
# download_configs - download the specified BOSH configs from the director {{{
sub download_configs {
	my ($self, @configs) = @_;
	@configs = qw/cloud runtime/ unless @configs;

	explain STDERR "Downloading configs from #M{%s} BOSH director...", $self->bosh->{alias};
	my $err;
	for (@configs) {
		my $file = "$self->{__tmp}/$_.yml";
		my ($type,$name) = split('@',$_);
		$name ||= '*';
		my $label = $name eq "*" ? "all $type configs" : $name eq "default" ? "$type config" : "$type config '$name'";
		waiting_on STDERR bullet('empty',$label."...", inline=>1, box => 1);
		my @downloaded = eval {$self->with_bosh->bosh->download_configs($file,$type,$name)};
		if ($@) {
			$err = $@;
			explain STDERR "\r".bullet('bad',$label.join("\n      ", ('...failed!',"",split("\n",$err),"")), box => 1, inline => 1);
		} else {
			explain STDERR "[2K\r".bullet('good',$label.($name eq '*' ? ':' : ''), box => 1, inline => 1);
			$self->use_config($file,$type,$name);
			for (@downloaded) {
				$self->use_config($file,$_->{type},$_->{name});
				explain STDERR bullet('good',$_->{label}, box => 1, inline => 1, indent => 7) if $name eq "*";
			}
		}
	}
	explain STDERR "";

	bail(
		"#R{[ERROR]} Could not fetch requested configs from #M{%s} BOSH director at #c{%s}\n",
		$self->bosh->{alias}, $self->bosh->{url}
	) if $err;
	return $self;
}

# }}}
# use_config - specify a local file to use for the given BOSH config {{{
sub use_config {
	my ($self,$file,$type,$name) = @_;
	$self->{__configs} ||= {};
	my $label = $type ||= 'cloud';
	my $env_var = "GENESIS_".uc($type)."_CONFIG";
	if ($name && $name ne '*') {
		$label .= "\@$name";
		$env_var .= "_$name";
	}
	$self->{__configs}{$label} = $file;
	$ENV{$env_var} = $file;
	return $self;
}

# }}}
# has_config - determine if the environment has the specific config file set {{{
sub has_config {
	my ($self, $type, $name) = @_;
	!!$self->config_file($type,$name);
}

# }}}
# config_file - retrieve the path of the local file (provided or downloaded) being used for the named BOSH config {{{
sub config_file {
	my ($self, $type, $name) = @_;
	my $label = $type ||= 'cloud';
	my $env_var = "GENESIS_".uc($type)."_CONFIG";
	if ($name && $name ne '*') {
		$label .= "\@$name";
		$env_var .= "_$name";
	}
	return $self->{__configs}{$label} || $ENV{$env_var} || '';
}

# }}}

# Legacy non-generic config methods {{{
# TODO: Remove these
sub download_cloud_config { $_[0]->download_configs('cloud'); }
sub use_cloud_config { $_[0]->use_config($_[1],'cloud'); }
sub cloud_config { return $_[0]->config_file('cloud'); }
sub download_runtime_config { $_[0]->download_configs('runtime'); }
sub use_runtime_config { $_[0]->use_config($_[1],'runtime'); }
sub runtime_config { return $_[0]->config_file('runtime'); }

# }}}

# Kit Components
# kit_files - get list of yaml files from the kit to be used to merge the manifest {{{
sub kit_files {
	my ($self, $absolute) = @_;
	$absolute = !!$absolute; #booleanify it.
	$self->{__kit_files}{$absolute} ||= [$self->kit->source_yaml_files($self, $absolute)];
	return @{$self->{__kit_files}{$absolute}};
}

# }}}
# has_hook - true if the environment's kit provides the specified hook {{{
sub has_hook {
	my $self = shift;
	return $self->kit->has_hook(@_);
}

# }}}
# run_hook - runs the specified hook in the environment's kit {{{
sub run_hook {
	my ($self, $hook, %opts) = @_;
	my @config_hooks = ($hook);
	push(@config_hooks, "addon-".$opts{script})
		if ($hook eq 'addon');

	$self->connect_required_endpoints(@config_hooks);
	$self->download_required_configs(@config_hooks);
	debug "Started run_hook '$hook'";
	return $self->kit->run_hook($hook, %opts, env => $self);
}

# }}}
# shell - provide a bash shell with the hook environment variables and helper functions available {{{
sub shell {
	my ($self, %opts) = @_;
	if ($opts{hook}) {
		my @config_hooks = ($opts{hook});

		if ($opts{hook} =~ /^addon-/) {
			$opts{hook_script} = $opts{hook};
			push(@config_hooks, "addon");
			$opts{hook} = "addon";
		}

		$self->connect_required_endpoints(@config_hooks);
		$self->download_required_configs(@config_hooks);
	}
	explain STDERR "#Y{Started shell environment for }#C{%s}#Y{:}", $self->name;
	return $self->kit->run_hook('shell', %opts, env => $self);
}

# }}}

# Manifest Management
# manifest - return the contents of the environments merged manifest as a hash {{{
sub manifest {
	my ($self, %opts) = @_;

	# prune by default.
	my ($redact,$prune,$vars_only) = @opts{qw(redact prune vars_only)};
	$prune = 1 unless defined $prune;

	trace "[env $self->{name}] in manifest(): Redact %s", defined($opts{redact}) ? "'$opts{redact}'" : '#C{(undef)}';
	trace "[env $self->{name}] in manifest(): Prune: %s", defined($opts{prune}) ? "'$opts{prune}'" : '#C{(undef)}';

	my (undef, $path) = $self->_manifest(get_opts(\%opts, qw/no_warnings partial redact/));

	if ($vars_only) {
		return run({
				onfailure => "Failed to merge $self->{name} manifest",
				stderr => "&1",
				env => $self->vault->env # to target desired vault
			},
			'spruce json "$1" | jq \'."bosh-variables"//{}\' | spruce merge --skip-eval', $path
		)."\n"
	}

	if ($prune) {
		my @prune = qw/meta pipeline params bosh-variables kit genesis exodus compilation/;
		if (!$self->use_create_env) {
			# bosh create-env needs these, so we only prune them
			# when we are deploying via `bosh deploy`.
			push(@prune, qw( resource_pools vm_types
			                 disk_pools disk_types
			                 networks
			                 azs
			                 vm_extensions));
		}

		debug("pruning top-level keys from #W{%s} manifest...", $redact ? 'redacted' : 'unredacted');
		debug("  - removing #C{%s} key...", $_) for @prune;
		return run({
				onfailure => "Failed to merge $self->{name} manifest",
				stderr => "&1",
				env => $self->vault->env # to target desired vault
			},
			'spruce', 'merge', '--skip-eval',  (map { ('--prune', $_) } @prune), $path)."\n";
	}

	debug("not pruning #W{%s} manifest.", $redact ? 'redacted' : 'unredacted');
	return slurp($path);
}

# }}}
# write_manifest - write the manifest out to the specified file {{{
sub write_manifest {
	my ($self, $file, %opts) = @_;
	my $out = $self->manifest(redact => $opts{redact}, prune => $opts{prune});
	mkfile_or_fail($file, $out);
}

# }}}
# cached_manifest_info - get the path, existance and sha1sum of the cached deployed manifest {{{
sub cached_manifest_info {
	my ($self) = @_;
	my $mpath = $self->path(".genesis/manifests/".$self->name.".yml");
	my $exists = -f $mpath;
	my $sha1 = $exists ? digest_file_hex($mpath, "SHA-1") : undef;
	return (wantarray ? ($mpath, $exists, $sha1) : $mpath);
}

# }}}
# vars_file - create yml file and return path for bosh variables {{{
sub vars_file {
	my ($self,$redact) = @_;

	# Check if manifest currently has params.variable-values hash, and if so,
	# build a variables.yml file in temp directory and return a path to it
	# (return undef otherwise)
	$redact = $redact ? 1 : 0;
	my $redacted = $redact ? '-redacted' : '';

	return $self->{_vars_file}{$redact} if ($self->{_vars_file}{$redact} && -f $self->{_vars_file}{$redact});

	my ($manifest, undef) = $self->_manifest(redact => $redact);
	my $vars = struct_lookup($manifest,'bosh-variables');
	if ($vars && ref($vars) eq "HASH" && scalar(keys %$vars) > 0) {
		my $vars_file = "$self->{__tmp}/bosh-vars${redacted}.yml";
		DumpYAML($vars_file,$vars);
		dump_var "BOSH Variables File" => $vars_file, "Contents" => slurp($vars_file);
		return $self->{_vars_file}{$redact} = $vars_file;
	} else {
		return undef
	}
}

# }}}

# Deployment
# check - check the environment {{{
sub check {
	# TODO: compare to genesis#check_environment
	my ($self,%opts) = @_;

	my $ok = 1;
	my $checks = "environmental parameters";
	$checks = "BOSH configs and $checks" if scalar($self->configs);

	if ($self->has_hook('check')) {
		explain STDERR "\n[#M{%s}] running $checks checks...", $self->name;
		$self->run_hook('check') or $ok = 0;
	} else {
		explain STDERR "\n[#M{%s}] #Y{%s does not define a 'check' hook; $checks checks will be skipped.}", $self->name, $self->kit->id;
	}

	if ($self->kit->secrets_store eq 'vault' && (!exists($opts{check_secrets}) || $opts{check_secrets})) {
		explain STDERR "\n[#M{%s}] running secrets checks...", $self->name;
		my %check_opts=(indent => '  ', validate => ! envset("GENESIS_TESTING_CHECK_SECRETS_PRESENCE_ONLY"));
		$ok = 0 unless $self->check_secrets(%check_opts);
	}

	if ($ok) {
		if (envset("GENESIS_CHECK_YAML_ON_DEPLOY") || $opts{check_yamls}) {
			if ($self->missing_required_configs('blueprint')) {
				explain STDERR "\n[#M{%s}] #Y{Required BOSH configs not provided - can't check manifest viability}", $self->name;
			} else {
				explain STDERR "\n[#M{%s}] inspecting YAML files used to build manifest...", $self->name;
				my @yaml_files = $self->format_yaml_files('include-kit' => 1, padding => '  ');
				explain STDERR join("\n",@yaml_files);
			}
		}
	}

	if ($ok) {
		if ($self->missing_required_configs('manifest')) {
			explain STDERR "\n[#M{%s}] #Y{Required BOSH configs not provided - can't check manifest viability}", $self->name;
		} elsif (!exists($opts{check_manifest}) || $opts{check_manifest}) {
			explain STDERR "\n[#M{%s}] running manifest viability checks...", $self->name;
			$self->manifest or $ok = 0;
		}
	}

	# TODO: secrets check for Credhub (post manifest generation)

	if ($ok && (!exists($opts{check_stemcells}) || $opts{check_stemcells}) && !$self->use_create_env) {

		explain STDERR "\n[#M{%s}] running stemcell checks...", $self->name;
		my @stemcells = $self->bosh->stemcells;
		my $required = $self->manifest_lookup('stemcells');
		my @missing;
		for my $stemcell_info (@$required) {
			my ($alias, $os, $version) = @$stemcell_info{qw/alias os version/};
			my ($wants_latest,$major_version) = $version =~ /^((?:(\d+)\.)?latest)$/;
			if ($wants_latest) {
				($version) = sort {$b <=> $a} map {$_->[1]}
				             grep {!$major_version || $major_version eq int($_->[1])}
				             grep {$_->[0] eq $os}
				             map {[split('@', $_)]} @stemcells;
			}
			$version ||= ''; # in case nothing was found
			my $found = grep {$_ eq "$os\@$version"} @stemcells;
			explain STDERR ("%sStemcell #C{%s} (%s/%s) %s",
				bullet($found ? 'good' : 'bad', '', box => 1, inline => 1),
				$alias, $os, $wants_latest ? $wants_latest : "v$version",
				$wants_latest ? (
					$found ? "#G{will use v$version}" : '#R{ - no stemcells available!}'
				) : (
					$found ? '#G{present.}' : '#R{missing!}'
				)
			);
			push(@missing, "$os@".($wants_latest || $version)) unless $found;
		}
		$ok = 0 if scalar(@missing);
		if (!$ok) {
			#TODO: if exodus data for bosh deployment indicates a version of the kit where
			#      https://github.com/genesis-community/bosh-genesis-kit/issues/70 is resolved,
			#      spit out the commands that allow the user to upload the specific missing verions:
			#      genesis -C path/to/bosh-env-file.yml do upload-stemcells os1/version1 os2/version2 ...
			explain STDERR "\n".
				"  Missing stemcells can be uploaded (if using BOSH kit v1.15.2 or higher):\n".
				"  #G{genesis -C <path/to/bosh-env-file.yml> do upload-stemcells %s}",
				join(' ',@missing);
		}
	}

	return $ok;
}

# }}}
# deploy - deploy the environment {{{
sub deploy {
	my ($self, %opts) = @_;

	unless ($self->use_create_env) {
		my @hooks = qw(blueprint manifest check);
		push @hooks, grep {$self->kit->has_hook($_)} qw(pre-deploy post-deploy);
		$self->download_required_configs(@hooks);
	}

	$self->check()
		or bail "#R{Preflight checks failed}; deployment operation #R{halted}.";

	explain STDERR "\n[#M{%s}] generating manifest...", $self->name;
	$self->write_manifest("$self->{__tmp}/manifest.yml", redact => 0);

	my ($ok, $predeploy_data,$data_fn);
	if ($self->has_hook('pre-deploy')) {
		($ok, $predeploy_data) = $self->run_hook(
			'pre-deploy',
			manifest  => $self->{__tmp}."/manifest.yml",
			vars_file => $self->vars_file
		);
		die "Cannot continue with deployment!\n" unless $ok;
		$data_fn = $self->tmppath("predeploy-data");
		mkfile_or_fail($data_fn, $predeploy_data) if ($predeploy_data);
	}

	my $disable_reactions = delete($opts{'disable-reactions'});
	my $reaction_vars;

	if ($self->_reactions) {
		if ($disable_reactions) {
			explain STDERR "\n#y{[WARNING]} Reactions are disabled for this deploy"
		} else {
			$self->_validate_reactions;
			$reaction_vars = {
				GENESIS_PREDEPLOY_DATAFILE => $data_fn,
				GENESIS_MANIFEST_FILE => $self->{__tmp}."/manifest.yml",
				GENESIS_BOSHVARS_FILE => $self->vars_file,
				GENESIS_DEPLOY_OPTIONS => JSON::PP::encode_json(\%opts),
				GENESIS_DEPLOY_DRYRUN => $opts{"dry-run"} ? "true" : "false"
			};
			$ok = $self->_process_reactions('pre-deploy', $reaction_vars);
			bail( "#R{[ERROR]} Cannnot deploy: environment pre-deploy reaction failed!") unless $ok;
		}
	}

	explain STDERR "\n[#M{%s}] all systems #G{ok}, initiating BOSH deploy...\n", $self->name;

	# Prepare the output manifest files for the repo
	my $manifest_file = $self->tmppath("out-manifest.yml");
	my $vars_file = $self->tmppath("out-vars.yml");
	$self->write_manifest($manifest_file, redact => 1, prune => 0);
	copy_or_fail($self->vars_file('redacted'), $vars_file) if ($self->vars_file('redacted'));

	# DEPLOY!!!
	if ($self->use_create_env) {
		debug("deploying this environment via `bosh create-env`, locally");
		my ($last_manifest_path,$last_exists,$old_sha1) = $self->cached_manifest_info;
		my $old_exodus = $self->exodus_lookup("",{});
		if ($last_exists) {
			explain "Showing differences between previous deployment found in archive:\n";
			if (! defined($old_exodus->{manifest_sha1})) {
				explain "#y{[WARNING]} Cannot confirm local cached deployment manifest pertains to the\n"
							. "          current deployment."
			} elsif ($old_exodus->{manifest_sha1} ne $old_sha1) {
				explain "#Y{[WARNING]} Latest deployment does not match the local cached deployment\n"
							. "          manifest, perhaps you need to perform a #C{git pull}.\n"
							. "          #R{This may mean your state file is also out of date!}"
			}
			my $rc = run({interactive => 1}, "spruce", "diff", $last_manifest_path, $manifest_file);
			explain "#y{NOTE}: values from vault have been redacted, so differences are not shown.";
		} else {
			explain "No previous deployment of this environment found in the deployment archive."
		}

		if (in_controlling_terminal && !envset('BOSH_NON_INTERACTIVE')) {
			my $confirm = prompt_for_boolean("Proceed with BOSH create-env for the #C{${\($self->name)}}? [y|n] ",1);
			bail "Aborted!\n" unless $confirm;
		} elsif ($last_exists && defined($old_exodus->{manifest_sha1}) && $old_exodus->{manifest_sha1} ne $old_sha1) {
			bail(
				"#R{[ERROR]} The local state file for #C{$self->{name}} may not be the\n"
			. "        state file from the last deployment.  Cowardly refusing to\n"
			. "        deploy -- run again without the -y argument to confirm."
			);
		} else {
			print "\n";
		}

		my @bosh_opts;
		push @bosh_opts, "--$_" for grep { $opts{$_} } qw/recreate skip-drain/;
		$ok = $self->bosh->create_env(
			"$self->{__tmp}/manifest.yml",
			vars_file => $self->vars_file,
			state => $self->path(".genesis/manifests/$self->{name}-state.yml"),
			store => $self->kit->secrets_store eq 'credhub' ? $self->path(".genesis/manifests/$self->{name}-store.json") : undef
		);

	} else {
		my @bosh_opts;
		push @bosh_opts, "--$_"             for grep { $opts{$_} } qw/fix fix-releases recreate dry-run/;
		push @bosh_opts, "--no-redact"      if  !$opts{redact};
		push @bosh_opts, "--skip-drain=$_"  for @{$opts{'skip-drain'} || []};
		push @bosh_opts, "--$_=$opts{$_}"   for grep { defined $opts{$_} } qw/canaries max-in-flight/;

		debug("deploying this environment to our BOSH director");
		$ok = $self->bosh->deploy(
			"$self->{__tmp}/manifest.yml",
			vars_file => $self->vars_file,
			flags      => \@bosh_opts
		);
	}

	explain STDERR "\n[#M{%s}] #G{Deployment successful.}\n", $self->name if $ok;

	if ($self->_reactions && !$disable_reactions) {
		$reaction_vars->{GENESIS_DEPLOY_RC} = ($ok ? 0 : 1);
		$self->_process_reactions('post-deploy', $reaction_vars) or explain STDERR (
			"#y{[WARNING]} Environment post-deploy reaction failed!  Manual intervention may be needed."
		);
	}

	# Don't do post-deploy stuff if just doing a dry run
	if ($opts{"dry-run"}) {
		explain STDERR "\n[#M{%s}] dry-run deployment complete; post-deployment activities will be skipped.";
		return $ok;
	}

	if ($ok) {
		# deployment succeeded; update the cache
		mkdir_or_fail($self->path(".genesis/manifests")) unless -d $self->path(".genesis/manifests");
		copy_or_fail($manifest_file, $self->path(".genesis/manifests/$self->{name}.yml"));
		copy_or_fail($vars_file, $self->path(".genesis/manifests/$self->{name}.vars")) if -e $vars_file;
	}

	unlink "$self->{__tmp}/manifest.yml"
		or debug "Could not remove unredacted manifest $self->{__tmp}/manifest.yml";

	# Reauthenticate to vault, as deployment can take a long time
	$self->vault->authenticate unless $self->vault->status eq 'sealed';

	$self->run_hook('post-deploy', rc => ($ok ? 0 : 1), data => $predeploy_data)
		if $self->has_hook('post-deploy');

	# bail out early if the deployment failed;
	# don't update the cached manifests
	return unless $ok;

	# track exodus data in the vault
	explain STDERR "\n[#M{%s}] Preparing metadata for export...", $self->name;
	$self->vault->authenticate unless $self->vault->authenticated;
	my $exodus = $self->exodus;

	$exodus->{manifest_sha1} = digest_file_hex($manifest_file, 'SHA-1');
	debug("setting exodus data in the Vault, for use later by other deployments");
	$ok = $self->vault->authenticate->query(
		{ onfailure => "#R{Failed to export $self->{name} metadata.}\n".
		               "Deployment was still successful, but metadata used by addons and other kits is outdated.\n".
		               "This may be resolved by deploying again, or it may be a permissions issue while trying to\n".
		               "write to vault path '".$self->exodus_base."'\n"
		},
		'rm',  $self->exodus_base, "-f",
		  '--', 'set', $self->exodus_base,
		               map { "$_=$exodus->{$_}" } grep {defined($exodus->{$_})} keys %$exodus);

	explain STDERR "\n[#M{%s}] #G{Done.}\n", $self->name;
	return $ok;
}

# }}}
# exodus - get the populated exodus data generated in the manifest {{{
sub exodus {
	my ($self) = @_;
	my $exodus = _flatten({}, undef, scalar($self->manifest_lookup('exodus', {})));
	my $vars_file = $self->vars_file;
	return $exodus unless ($vars_file || $self->kit->uses_credhub);

	#interpolate bosh vars first
	if ($vars_file) {
		for my $key (keys %$exodus) {
			if (defined($exodus->{$key}) && $exodus->{$key} =~ /^\(\((.*)\)\)$/) {
				$exodus->{$key} = $self->manifest_lookup("bosh-variables.$1", $exodus->{$key});
			}
		}
	}

	my @int_keys = grep {$exodus->{$_} =~ /^\(\(.*\)\)$/} grep {defined($exodus->{$_})} keys %$exodus;
	if ($self->kit->uses_credhub && @int_keys) {
		# Get credhub info
		my %credhub_env = $self->credhub_connection_env;
		my $credhub_exodus = $self->exodus_lookup("", {}, $credhub_env{GENESIS_CREDHUB_EXODUS_SOURCE});
		my @missing = grep {!exists($credhub_exodus->{$_})} qw/ca_cert credhub_url credhub_ca_cert credhub_password credhub_username/;
		bail("#R{[ERROR]} %s exodus data missing required credhub connection information: %s\nRedeploying it may help.",
			$credhub_env{GENESIS_CREDHUB_EXODUS_SOURCE}, join (', ', @missing))
			if @missing;

		local %ENV=%ENV;
		$ENV{$_} = $credhub_env{$_} for (grep {$_ =~ /^CREDHUB_/} keys(%credhub_env));
		for my $target (@int_keys) {
			my ($secret,$key) = ($exodus->{$target} =~ /^\(\(([^\.]*)(?:\.(.*))?\)\)$/);
			next unless $secret;
			my @keys; @keys = ("-k", $key) if defined($key);
			my ($out, $rc, $err) = run({stderr => 0},
				"credhub", "get", "-n", $credhub_env{GENESIS_CREDHUB_ROOT}."/$secret", @keys, "-q"
			);
			if ($rc) {
				error("#R{[ERROR]} Could not retrieve %s under %s:\n%s",
				  $key ? "$secret.$key" : $secret, $credhub_env{GENESIS_CREDHUB_ROOT}, $err
				);
			}
			$exodus->{$target} = $out;
		}
	}
	return $exodus;
}

# }}}


# Secrets Processing
# add_secrets - add any secrets missing from the environment {{{
sub add_secrets {
	my ($self, %opts) = @_;

	#Credhub check
	if ($self->kit->uses_credhub) {
		explain "#Yi{Credhub-based kit - no local secrets generation required}";
		return 1;
	}

	if ($self->has_hook('secrets')) {
		$self->run_hook('secrets', action => 'add')
	} else {
		# Determine secrets_store from kit - assume vault for now (credhub ignored)
		my $store = $self->vault->connect_and_validate;
		my $processing_opts = {
			level=>$opts{verbose}?'full':'line'
		};
		my $ok = $store->process_kit_secret_plans(
			'add',
			$self,
			sub{$self->_secret_processing_updates_callback('add',$processing_opts,@_)},
			get_opts(\%opts, qw/paths/)
		);
		return $ok;
	}
}

# }}}
# check_secrets - check that the environment has no missing or invalid secrets {{{
sub check_secrets {
	my ($self,%opts) = @_;

	#Credhub check
	if ($self->kit->uses_credhub) {
		explain "#Yi{Credhub-based kit - no local secrets validation required}\n";
		return 1;
	}

	if ($self->has_hook('secrets')) {
		$self->run_hook('secrets', action => 'check');
	} else {
		# Determine secrets_store from kit - assume vault for now (credhub ignored)
		my $store = $self->vault->connect_and_validate;
		my $action = $opts{validate} ? 'validate' : 'check';
		my $processing_opts = {
			no_prompt => $opts{'no-prompt'},
			level=>$opts{verbose}?'full':'line'
		};
		my $ok = $store->validate_kit_secrets(
			$action,
			$self,
			sub{$self->_secret_processing_updates_callback($action,$processing_opts,@_)},
			get_opts(\%opts, qw/paths validate/)
		);
		return $ok;
	}
}

# }}}
# rotate_secrets - generate new secrets for the environment {{{
sub rotate_secrets {
	my ($self, %opts) = @_;

	#Credhub check
	if ($self->kit->uses_credhub) {
		explain "#Yi{Credhub-based kit - no local secrets rotation allowed}";
		return 1;
	}

	my $action = $opts{'renew'} ? 'renew' : 'recreate';
	if ($self->has_hook('secrets')) {
		$self->run_hook('secrets', action => $action);
	} else {
		# Determine secrets_store from kit - assume vault for now (credhub ignored)
		my $store = $self->vault->connect_and_validate;
		my $processing_opts = {
			no_prompt => $opts{'no-prompt'},
			level=>$opts{verbose}?'full':'line'
		};
		my $ok = $store->process_kit_secret_plans(
			$action,
			$self,
			sub{$self->_secret_processing_updates_callback($action,$processing_opts,@_)},
			get_opts(\%opts, qw/paths no_prompt interactive invalid/)
		);
		return $ok;
	}
}

# }}}
# remove_secrets - remove secrets from the environment {{{
sub remove_secrets {
	my ($self, %opts) = @_;

	#Credhub check
	if ($self->kit->uses_credhub) {
		explain "#Yi{Credhub-based kit - no local secrets removal permitted}";
		return 1;
	}

	# Determine secrets_store from kit - assume vault for now (credhub ignored)
	my $store = $self->vault->connect_and_validate;
	my @generated_paths;
	if ($opts{all}) {
		my @paths = $self->vault->paths($self->secrets_base);
		return 2 unless scalar(@paths);

		unless ($opts{'no-prompt'}) {
			die_unless_controlling_terminal "#R{[ERROR] %s", join("\n",
				"Cannot prompt for confirmation to remove all secrets outside a",
				"controlling terminal.  Use #C{-y|--no-prompt} option to provide confirmation",
				"to bypass this limitation."
			);
			explain "\n#Yr{[WARNING]} This will delete all %s secrets under '#C{%s}', including\n".
			             "          non-generated values set by 'genesis new' or manually created",
				 scalar(@paths), $self->secrets_base;
			while (1) {
				my $response = prompt_for_line(undef, "Type 'yes' to remove these secrets, 'list' to list them; anything else will abort","");
				print "\n";
				if ($response eq 'list') {
					# TODO: check and color-code generated vs manual entries
					my $prefix_len = length($self->secrets_base)-1;
					bullet $_ for (map {substr($_, $prefix_len)} @paths);
				} elsif ($response eq 'yes') {
					last;
				} else {
					explain "\nAborted!\nKeeping all existing secrets under '#C{%s}'.\n", $self->secrets_base;
					return 0;
				}
			}
		}
		waiting_on "Deleting existing secrets under '#C{%s}'...", $self->secrets_base;
		my ($out,$rc) = $self->vault->query('rm', '-rf', $self->secrets_base);
		bail "#R{error!}\n%s", $out if ($rc);
		explain "#G{done}\n";
		return 1;
	}

	if ($self->has_hook('secrets')) {
		$self->run_hook('secrets', action => 'remove');
	} else {
		my $processing_opts = {
			level=>$opts{verbose}?'full':'line'
		};
		my $ok = $store->process_kit_secret_plans(
			'remove',
			$self,
			sub{$self->_secret_processing_updates_callback('remove',$processing_opts,@_)},
			get_opts(\%opts, qw/paths no_prompt interactive invalid/)
		);
		return $ok;
	}
}

# }}}
# }}}

### Private Instance Methods {{{

# _manifest - build or return cached manifest (with/out redaction and pruning) {{{
sub _manifest {
	my ($self, %opts) = @_;
	trace "[env $self->{name}] in _manifest(): Redact %s", defined($opts{redact}) ? "'$opts{redact}'" : '#C{(undef)}';
	my $which = ($opts{partial} ? '__partial' : "").($opts{redact} ? '__redacted' : '__unredacted');
	my $path = "$self->{__tmp}/$which.yml";

	trace("[env $self->{name}] in _manifest(): looking for the '$which' cached manifest");
	if (!$self->{$which}) {
		trace("[env $self->{name}] in ${which}_manifest(): cache MISS; generating");
		trace("[env $self->{name}] in ${which}_manifest(): cwd is ".Cwd::cwd);

		my @merge_files = $self->_yaml_files($opts{partial});
		trace("[env $self->{name}] in _manifest(): merging $_") for @merge_files;

		pushd $self->path;
		my $out;
		my $env = {
			$self->get_environment_variables('manifest'),
			%{$self->vault->env()},               # specify correct vault for spruce to target
			REDACT => $opts{redact} ? 'yes' : '' # spruce redaction flag
		};
		if ($opts{partial}) {
			debug("running spruce merge of all files, without evaluation or cloudconfig, for parameter dereferencing");
			($out, my $warnings) = $self->adaptive_merge({env => $env}, @merge_files);
			error "\nErrors encountered and bypassed during partial merge.  These operators have been left unresolved:\n$warnings\n"
				if $warnings && ! $opts{no_warnings};
		} else {
			debug("running spruce merge of all files, with evaluation, to generate a manifest");
			$out = run({
					onfailure => "Unable to merge $self->{name} manifest",
					stderr => "&1",
					env => $env
				},
				'spruce', 'merge', '--multi-doc', '--go-patch', @merge_files
			);
		}
		popd;

		debug("saving #W{%s%s} manifest to $path", $opts{partial} ? 'partial ' : '',  $opts{redact} ? 'redacted' : 'unredacted');
		mkfile_or_fail($path, 0400, $out);
		$self->{$which} = load_yaml($out);
	} else {
		trace("[env $self->{name}] in ${which}_manifest(): cache HIT!");
	}
	return $self->{$which}, $path;
}

# }}}
# _genesis_inherits - return the list of inherited files (recursive) {{{
sub _genesis_inherits {
	my ($self,$file, @files) = @_;
	my ($out,$rc,$err) = run({stderr => 0},'cat "$1" | spruce json', $self->path($file));
	bail "Error processing json in $file!:\n$err" if $rc;
	my @contents = map {load_json($_)} lines($out);

	my @new_files;
	for my $contents (@contents) {
		next unless $contents->{genesis}{inherits};
		bail "#R{[ERROR]} $file specifies 'genesis.inherits', but it is not a list"
			unless ref($contents->{genesis}{inherits}) eq 'ARRAY';

		for (@{$contents->{genesis}{inherits}}) {
			my $cached_file;
			if ($ENV{PREVIOUS_ENV}) {
				$cached_file = ".genesis/cached/$ENV{PREVIOUS_ENV}/$_.yml";
				$cached_file = undef unless -f $self->path($cached_file);
			}
			my $inherited_file = $cached_file || "./$_.yml";
			next if grep {$_ eq $inherited_file} @files;
			push(@new_files, $self->_genesis_inherits($inherited_file,$file,@files,@new_files),$inherited_file);
		}
	}
	return(@new_files);
}

# }}}
# _secret_processing_updates_callback - callback for secrets processing UI {{{
sub _secret_processing_updates_callback {
	my ($self,$action,$opts,$state,%args) = @_;
	my $indent = $opts->{indent} || '  ';
	my $level = $opts->{level} || 'full';
	$level = 'full' unless -t STDOUT;

	$action = $args{action} if $args{action};
	$args{result} ||= '';
	(my $actioned = $action) =~ s/e?$/ed/;
	$actioned = 'found' if $actioned eq 'checked';
	(my $actioning = $action) =~ s/e?$/ing/;

	if ($state eq 'done-item') {
		my $map = { 'validate/error' => "#R{invalid!}",
		            error => "#R{failed!}",
		            'check/ok' =>  "#G{found.}",
		            'validate/ok' =>  "#G{valid.}",
		            'validate/warn' => "#Y{warning!}",
		            ok =>  "#G{done.}",
		            'recreate/skipped' => '#Y{skipped}',
		            'remove/skipped' => '#Y{skipped}',
		            skipped => "#Y{exists!}",
		            missing => "#R{missing!}" };
		push(@{$self->{__secret_processing_updates_callback__items}{$args{result}} ||= []},
		     $self->{__secret_processing_updates_callback__item});

		explain $map->{"$action/$args{result}"} || $map->{$args{result}} || $args{result}
			if $args{result} && ($level eq 'full' || !( $args{result} eq 'ok' || ($args{result} eq 'skipped' && $action eq 'add')));

		if (defined($args{msg})) {
			my @lines = grep {$level eq 'full' || $_ =~ /^\[#[YR]/} split("\n",$args{msg});
			my $pad = " " x (length($self->{__secret_processing_updates_callback__total})*2+4);
			explain "  $pad%s", join("\n  $pad", @lines) if @lines;
			explain "" if $level eq 'full' || scalar @lines;
		}
		waiting_on "\r[2K" unless $level eq 'full';

	} elsif ($state eq 'start-item') {
		$self->{__secret_processing_updates_callback__idx}++;
		my $w = length($self->{__secret_processing_updates_callback__total});
		my $long_warning='';
		if ($args{label} eq "Diffie-Hellman key exchange parameters" && $action =~ /^(add|recreate)$/) {
			$long_warning = ($level eq 'line' ? " - " : "; ")."#Yi{may take a very long time}"
		}
		waiting_on "  [%*d/%*d] #C{%s} #wi{%s}%s ... ",
			$w, $self->{__secret_processing_updates_callback__idx},
			$w, $self->{__secret_processing_updates_callback__total},
			$args{path},
			$args{label} . ($level eq 'line' || !$args{details} ? '' : " - $args{details}"),
			$long_warning;

	} elsif ($state eq 'empty') {
		explain "%s - nothing to %s!\n",
			$args{msg} || "No kit secrets found",
			$action;
		return 1;

	} elsif ($state eq 'abort') {
		error($args{msg}) if $args{msg};
		return;

	} elsif ($state eq 'init') {
		$self->{__secret_processing_updates_callback__start} = time();
		$self->{__secret_processing_updates_callback__total} = $args{total};
		$self->{__secret_processing_updates_callback__idx} = 0;
		$self->{__secret_processing_updates_callback__items} = {};
		my $msg_action = $args{action} || sprintf("%s %s secrets", ucfirst($actioning), $args{total});
		explain "\n%s for #M{%s} under path '#C{%s}':", $msg_action, $self->name, $self->secrets_base;

	} elsif ($state eq 'wait') {
		$self->{__secret_processing_updates_callback__startwait} = time();
		waiting_on "%s ... ", $args{msg};

	} elsif ($state eq 'wait-done') {
		explain("%s #Ki{- %s}",
			$args{result} eq 'ok' ? "#G{done.}" : "#R{error!}",
			Time::Seconds->new(time() - $self->{__secret_processing_updates_callback__startwait})->pretty()
		) if ($args{result} && ($args{result} eq 'error' || $level eq 'full'));
		error("#R{[ERROR]} Encountered error: %s", $args{msg}) if ($args{result} eq 'error');
		waiting_on "\r[2K" unless $level eq 'full';

	} elsif ($state eq 'completed') {
		my @extra_errors = @{$args{errors} || []};
		my $warn_count = scalar(@{$self->{__secret_processing_updates_callback__items}{warn} || []});
		my $err_count = scalar(@{$self->{__secret_processing_updates_callback__items}{error} || []})
			+ scalar(@extra_errors)
			+ ($action =~ /^(check|validate)$/ ?
				scalar(@{$self->{__secret_processing_updates_callback__items}{missing} || []}) : 0);
		explain "%s - Duration: %s [%d %s/%d skipped/%d errors%s]\n",
			$err_count ? "Failed" : "Completed",
			Time::Seconds->new(time() - $self->{__secret_processing_updates_callback__start})->pretty(),
			scalar(@{$self->{__secret_processing_updates_callback__items}{ok} || []}), $actioned,
			scalar(@{$self->{__secret_processing_updates_callback__items}{skipped} || []}),
			$err_count,
			$warn_count ? "/$warn_count warnings" : '';
		$err_count += $warn_count
			if (($opts->{invalid}||0) == 2 || ($opts->{validate}||0) == 2);
		return !$err_count;
	} elsif ($state eq 'inline-prompt') {
		die_unless_controlling_terminal "#R{[ERROR] %s", join("\n",
			"Cannot prompt for confirmation to $action secrets outside a",
			"controlling terminal.  Use #C{-y|--no-prompt} option to provide confirmation",
			"to bypass this limitation."
		);
		print "[s\n[u[B[A[s"; # make sure there is room for a newline, then restore and save the current cursor
		my $response = Genesis::UI::__prompt_for_line($args{prompt}, $args{validation}, $args{err_msg}, $args{default}, !$args{default});
		print "[u[0K";
		return $response;
	} elsif ($state eq 'prompt') {
		my $title = '';
		if ($args{class}) {
			$title = sprintf("\r[2K\n#%s{[%s]} ", $args{class} eq 'warning' ? "Y" : '-', uc($args{class}));
		}
		explain "%s%s", $title, $args{msg};
		die_unless_controlling_terminal "#R{[ERROR] %s", join("\n",
			"Cannot prompt for confirmation to $action secrets outside a",
			"controlling terminal.  Use #C{-y|--no-prompt} option to provide confirmation",
			"to bypass this limitation."
		);
		return prompt_for_line(undef, $args{prompt}, $args{default} || "");
	} elsif ($state eq 'notify') {
		if ($args{nonl}) {
			waiting_on $args{msg};
		} else {
			explain $args{msg};
		}
	} else {
		bug "_secret_processing_updates_callback encountered an unknown state '$state'";
	}
}

# }}}
# _yaml_files - create genisis support yml files and return full ordered merge list {{{
sub _yaml_files {
	my ($self,$partial) = @_;
	(my $vault_path = $self->secrets_base) =~ s#/?$##; # backwards compatibility
	my $type   = $self->{top}->type;

	my @cc;
	if ($self->use_create_env) {
		trace("[env $self->{name}] in_yaml_files(): IS a create-env, skipping cloud-config");
	} elsif ($partial) {
		trace("[env $self->{name}] in_yaml_files(): skipping eval, no need for cloud-config");
		push @cc, $self->config_file('cloud') if $self->config_file('cloud'); # use it if its given
	} else {
		trace("[env $self->{name}] in _yaml_files(): not a create-env, we need cloud-config");

		$self->download_required_configs('blueprint');
		my $ccfile =  $self->config_file('cloud');

		die "No cloud-config specified for this environment\n"
			unless $ccfile;
		trace("[env $self->{name}] in _yaml_files(): cloud-config at $ccfile");
		push @cc, $ccfile;
	}

	if ($self->kit->feature_compatibility('2.6.13')) {
		mkfile_or_fail("$self->{__tmp}/init.yml", 0644, <<EOF);
---
meta:
  vault: $vault_path
kit:
  features: []
exodus:  {}
genesis: {}
params:  {}
EOF
	} else {
		mkfile_or_fail("$self->{__tmp}/init.yml", 0644, <<EOF);
---
meta:
  vault: $vault_path
kit:
  features: []
exodus: {}
genesis: {}
params:
  env:  (( grab genesis.env ))
  name: (( concat genesis.env || params.env "-$type" ))
EOF
	}

	my $now = strftime("%Y-%m-%d %H:%M:%S +0000", gmtime());
	my $bosh_target = $self->use_create_env ? "~" : ($self->bosh_env || $self->name);
	mkfile_or_fail("$self->{__tmp}/fin.yml", 0644, <<EOF);
---
name: (( concat genesis.env "-$type" ))
genesis:
  env:           ${\(scalar $self->lookup(['genesis.env','params.env'], $self->name))}
  secrets_path:  ${\($self->secrets_slug)}
  secrets_mount: ${\($self->secrets_mount)}
  exodus_path:   ${\($self->exodus_slug)}
  exodus_mount:  ${\($self->exodus_mount)}
  ci_mount:      ${\($self->ci_mount)}${\(
  ($self->use_create_env || $self->bosh_env eq $self->name) ? "" :
  "\n  bosh_env:      $bosh_target")}

exodus:
  version:        $Genesis::VERSION
  dated:          $now
  deployer:       (( grab \$CONCOURSE_USERNAME || \$USER || "unknown" ))
  kit_name:       ${\($self->kit->metadata->{name} || 'unknown')}
  kit_version:    ${\($self->kit->metadata->{version} || '0.0.0-rc0')}
  kit_is_dev:     ${\(ref($self->kit) eq "Genesis::Kit::Dev" ? 'true' : 'false')}
  vault_base:     (( grab meta.vault ))
  bosh:           $bosh_target
  is_director:    ${\($self->is_bosh_director ? 'true' : 'false')}
  use_create_env: ${\($self->use_create_env ? 'true' : 'false')}
  features:       (( join "," kit.features ))
EOF
	# TODO: In BOSH refactor, add the bosh director to the exodus data
	my @environment_files;
	return (
		"$self->{__tmp}/init.yml",
		$self->kit_files(1), # absolute
		@cc,
		$self->actual_environment_files(),
		"$self->{__tmp}/fin.yml",
	);
}

# }}}
# _flatten - convert deep structure to single sequence of key:value {{{
sub _flatten {
	my ($final, $key, $val) = @_;

	if (ref $val eq 'ARRAY') {
		for (my $i = 0; $i < @$val; $i++) {
			_flatten($final, $key ? "${key}[$i]" : "$i", $val->[$i]);
		}

	} elsif (ref $val eq 'HASH') {
		for (keys %$val) {
			_flatten($final, $key ? "$key.$_" : "$_", $val->{$_})
		}

	} else {
		$final->{$key} = $val;
	}

	return $final;
}

# }}}
# _unflatten - convert a flattened hashmap to a deep structure {{{
sub _unflatten {
	my ($data, $branch) = @_;

	return $data unless ref($data) eq 'HASH'; # Catchall for scalar data coming in.

	# Data must represent all array elements or all hash keys.
	my ($elements, $keys) = ([],[]);
	push @{($_ =~ /^\[\d+\](?:\.|\[|$)/) ? $elements : $keys}, $_ for (sort keys %$data);
	die("Cannot unflatten data that contains both array elements and hash keys at same level "
		 . ($branch ? "(at $branch)" : "(top level)") ."\n") if @$elements && @$keys;

	if (@$elements) {
		my @a_data;
		for my $k (sort keys %$data) {
			my ($i, $sk) = $k =~ /^\[(\d+)\](?:\.)?([^\.].*)?$/;
			if (defined $sk) {
				die "Array cannot have scalar and non-scalar values (at ${branch}[$i])"
					if defined $a_data[$i] && ref($a_data[$i]) ne 'HASH';
				$a_data[$i]->{$sk} = delete $data->{$k};
			} else {
				die "Array cannot have scalar and non-scalar values (at ${branch}[$i])"
					if defined $a_data[$i];
				$a_data[$i] = delete $data->{$k};
			}
		}
		for my $i (0..$#a_data) {
			$a_data[$i] = _unflatten($a_data[$i], ($branch||"")."[$i]");
		}
		return [@a_data];
	} else {
		my %h_data;
		for my $k (sort keys %$data) {
			my ($pk, $sk) = $k =~ /^([^\[\.]*)(?:\.)?([^\.].*?)?$/;
			if (defined $sk) {
				die "Hash cannot have scalar and non-scalar values (at ".join('.', grep $_, ($branch, "pk")).")"
					if defined $h_data{$pk} && ref($h_data{$pk}) ne 'HASH';
				$h_data{$pk}->{$sk} = delete $data->{$k};
			} else {
				die "Hash cannot have scalar and non-scalar values (at ".join('.', grep $_, ($branch, "pk")).")"
					if defined $h_data{$pk};
				$h_data{$pk} = delete $data->{$k};
			}
		}
		for my $k (sort keys %h_data) {
			$h_data{$k} = _unflatten($h_data{$k}, join('.', grep $_, ($branch, "$k")));
		}
		return {%h_data}
	}
}

# }}}

# }}}
# _reactions - list of reactions specified in the environment file. {{{
sub _reactions {
	return @{
		$_[0]->_memoize(sub {
				[sort keys (%{$_[0]->lookup("genesis.reactions",{})})]
			})
	};
}

# }}}
# _validate_reactions - ensure user hasn't specified any in valid reation types {{{
sub _validate_reactions {
	my @valid_reactions = qw/pre-deploy post-deploy/;
	my %reaction_validator; @reaction_validator{@valid_reactions} = ();
	my @invalid_reactions = grep ! exists $reaction_validator{$_}, ( $_[0]->_reactions );
	if (@invalid_reactions) {
		bail "\n#R{[ERROR]} Unexpected reactions specified under #y{genesis.reactions}: #R{%s}\n".
		     "        Valid values: #G{%s}",
		     join(', ', @invalid_reactions), join(', ',@valid_reactions);
	}
	return;
}

# }}}
# _process_reactions - handle the specified environment reaction scripts {{{
sub _process_reactions {
	my ($self, $reaction, $reaction_vars) = @_;
	my $ok = 1;

	if ($self->lookup("genesis.reactions.$reaction")) {
		my %env_vars = $self->get_environment_variables('deploy');
		my $actions = $self->lookup("genesis.reactions.$reaction");
		explain STDERR '';
		bail(
			"#R{[ERROR]} Value of #C{genesis.reactions.%s} must be a list of one or more hashmaps",
			$reaction
		) if ref($actions) ne "ARRAY" || scalar(@{$actions}) == 0;

		for my $action (@{$actions}) {
			bail(
				"#R{[ERROR]} Values in #C{genesis.reactions.i%s} list must be hashmaps",
				$reaction
			) if ref($action) ne "HASH";
			my @action_type = grep {my $i = $_; grep {$_ eq $i} qw/script addon/} keys(%{$action});
			bail(
				"#R{[ERROR]} Values in #C{genesis.reactions.%s} must have one #C{script} or #C{addon} key",
				$reaction
			) unless scalar(@action_type) == 1;
			my $script = $action->{$action_type[0]};
			if ($action_type[0] eq "script") {
				my @args = @{$action->{args}||[]};
				my @cmd = ('bin/'.$action->{script}, @args);
				explain STDERR "#M{[%s: }#mi{%s}#M{]} Running script \`#G{%s}\` with %s:\n",
					$self->name, uc($reaction), $cmd[0], (
						@args ? sprintf('arguments of [#C{%s}]', join(', ',map {"\"$_\""} @args)) : 'no arguments'
					);
				my ($out, $rc) = run({
						dir => $env_vars{GENESIS_ROOT},
						eval_var_args => 1,
						interactive => 1,
						env => {%env_vars,%{$reaction_vars}}
					},
					@cmd
				);
				$ok = $rc == 0;
				if ($ok && defined($action->{var})) {
					$reaction_vars->{$action->{var}} = $out;
				}
			} else {
				bail(
					"#R{Kit %s does not provide an addon hook!}",
					$self->kit->id
				) unless $self->has_hook('addon');

				$self->download_required_configs('addon', "addon-$script");

				explain STDERR "#M{[%s: }#mi{%s}#M{]} Running #G{%s} addon from kit #M{%s}:\n", $self->name, uc($reaction), $script, $self->kit->id;
				$ok = $self->run_hook('addon', script => $script, args => $action->{args}, eval_var_args => 1, extra_vars => $reaction_vars);
			}
			explain STDERR '';
			last unless $ok;
		}
	}
	return $ok;
}

# }}}
# _parse_bosh_env - parse the bosh env into its constituent parts {{{
sub _parse_bosh_env {
	my $self = shift;
	return ($self->bosh_env =~ m/^([^\/\@]+)(?:\/([^\@]+))?(?:@(?:(https?:\/\/[^\/]+)?\/)?(.*))?$/);
}

# }}}
# }}}
1;

=head1 NAME

Genesis::Env

=head1 DESCRIPTION

The Env class represents a single, deployable unit of YAML files in a
Genesis deployment repository / working directory, and wraps up all of the
core rules for dealing with the set as a whole.

To load an existing environment, all you need is the C<Genesis::Top> object
that represents the top of the deployment repository, and the name of the
environment you want:

    use Genesis::Top;
    use Genesis::Env;

    my $top = Genesis::Top->new('.');
    my $env = Genesis::Env->new(
      top  => $top,
      name => 'us-west-1-preprod',
    );

To create a new environment, you need a bit more information.  You also need
to be ready to run through interactive ask-the-user-questions mode, for
things like the `new` hook:

    my $env = Genesis::Env->create(
       top  => $top,
       name => 'us-west-1-preprod',
       kit  => $top->local_kit_version('some-kit', 'latest'),
    );

It can optionally take the following options to modify the default `vault`
behaviour:
  * secrets_mount - the mount point for secrets (default: /secrets/)
  * exodus_mount  - the mount point for exodus data (default: $secrets_mount/exodus)
  * ci_mount      - the mount point for ci secrets (default: $secrets_mount/ci)
  * secrets_path  - the path under the secrets_mount for the environment secrets
                    (defaults to env-name-split-by-hyphens/deployment-type)
  * root_ca_path  - specified a path to a common root CA to sign all otherwise
                    self-signed certificates
  * credhub_env   - used to specify the environment that provides the credhub
                    login credentials (defaults to bosh environment)

You can also avail yourself of the C<new> constructor, which does a lot of
the validation, but won't access the environment files directly:

    my $env = Genesis::Env->new(
       top  => $top,
       name => 'us-west-1-preprod',
    );

=head1 CONSTRUCTORS

=head2 new(%opts)

Create a new Env object without making any assertions about the filesystem.
Usually, this is not the constructor you want.  Check out C<load> or
C<create> instead.

The following options are recognized:

=over

=item B<name> (required)

The name of your environment.  See NAME VALIDATION for details on naming
requirements.  This option is B<required>.

=item B<top> (required)

The Genesis::Top object that represents the root working directory of the
deployments repository.  This is used to fetch things like deployment
configuration, kits, etc.  This option is B<required>.

=item B<secrets_path>

A path in the Genesis Vault, under which secrets for this environment should
be stored.  Normally, you don't need to specify this.  When an environment
is loaded, it will probably be overridden by the operators C<param>s.
Otherwise, Genesis can figure out the correct default value.

=back

Unrecognized options will be silently ignored.

=head2 load(%opts)

Create a new Env object by loading its definition from constituent YAML
files on-disk (by way of the given Genesis::Top object).  If the given
environment does not exist on-disk, this constructor will throw an error
(via C<die>), so you may want to C<eval> your call to it.

C<load> does not recognize additional options, above and beyond those which
are handled by and required by C<new>.

=head2 exists(%opts)

Returns true if the environment defined by the options exist.

=head2 create(%opts)

Create a new Env object by running the user through the wizardy setup of the
C<hooks/new> kit hook.  This often cannot be run unattended, and definitely
cannot be run without access to the Genesis Vault.

If the named environment already exists on-disk, C<create> throws an error
and dies.

C<create> recognizes the following options, in addition to those recognized
by (and required by) C<new>:

=over

=item B<kit> (required)

A Genesis::Kit object that represents the Genesis Kit to use for
provisioning (and eventually deploying) this environment.  This option is
required.

=back

=head1 CLASS FUNCTIONS

=head2 _validate_env_name($name)

Validates an environment name, according to the following rules:

=over

=item 1.

Names must not be empty.

=item 2.

They cannot contain whitespace

=item 3.

They must consist entirely of lowercase letters, numbers, and hyphens

=item 4.

Names must start with a letter, and cannot end with a hyphen

=item 5.

Sequential hyphens (C<-->) are expressly prohibited

=back

=head1 METHODS

=head2 name()

Retrieves the bare environment name (without the file suffix).

=head2 file()

Retrieves the file name of the final environment file.  This is just the
name with a C<.yml> suffix attached.


=head2 deployment()

Retrieves the BOSH deployment name for this environment, which is based off
of the environment name and the root directory repository type (i.e.
C<bosh>, C<concourse>, etc.)


=head2 secrets_path()

Retrieve the Vault secrets_path that this environment should store its secrets
under, based off of either its name (by default) or its C<genesis.secrets_path>
parameter.  Legacy environments may also have this specified by C<params.vault>
or C<params.vault_prefix>

=head2 kit()

Retrieve the Genesis::Kit object for this environment.

=head2 tmppath($relative)

Retrieve a temporary work path the given C<$relative> path for this environment.
If no relative path is given, it returns the temporary root directory.

=head2 type()

Retrieve the deployment type for this Genesis::Kit object.

=head2 path([$relative])

Returns the absolute path to the root directory, with C<$relative> appended
if it is passed.

=head2 use_cloud_config($file)

Use the given BOSH cloud-config (as defined in C<$file>) when merging this
environments manifest.  This must be called before calls to C<manifest()>,
C<write_manifest()>, or C<manifest_lookup()>.

=head2 download_cloud_config()

Download a cloud-config file from the BOSH director, and set the environment
to use it.  This can be used in leiu of C<use_cloud_config>.

=head2 cloud_config

Returns the path to the cloud-config file that has been associated with this
environment or empty string if no cloud-config present.

=head2 relate($them, [$cachedir, [$topdir])

Relates an environment to another environment, and returns the set of
possible YAML files that could comprise the environment.  C<$them> can
either be another Env object, or the name of an environment, as a string.

This method returns either a list of files (in list mode) or a hashref
containing the set of common files and the set of unique files.  Aside from
that, it's actually really hard to explain I<what> it does, without resoring
to examples.  Without further ado:

    my $a = Genesis::Env->new(name => "us-west-1-preprod");
    my @files = $a->relate('us-west-1-prod');

    #
    # returns:
    #   - ./us.yml
    #   - ./us-west.yml
    #   - ./us-west-1.yml
    #   - ./us-west-1-preprod.yml
    #

The real fun begins when you pass a directory prefix as the second argument:

    my $a = Genesis::Env->new(name => "us-west-1-preprod");
    my @files = $a->relate('us-west-1-prod', '.cache');

    #
    # returns:
    #   - .cache/us.yml
    #   - .cache/us-west.yml
    #   - .cache/us-west-1.yml
    #   - ./us-west-1-preprod.yml
    #

Notice that the first three file paths returned are inside of the C<./cache>
directory, since those constituent YAML files are common to both
environments.  This is how the Genesis CI/CD pipelines handle propagation of
environmental changes.

If you pass a third argument, it affects the I<unique set>, YAML files that
only affect the first environment:

    my $a = Genesis::Env->new(name => "us-west-1-preprod");
    my @files = $a->relate('us-west-1-prod', 'old', 'NEW');

    #
    # returns:
    #   - old/us.yml
    #   - old/us-west.yml
    #   - old/us-west-1.yml
    #   - NEW/us-west-1-preprod.yml
    #

In scalar mode, the two sets (I<common> and I<unique>) are returned as array
references under respecitvely named hashref keys:


    my $a = Genesis::Env->new(name => "us-west-1-preprod");
    my $files = $a->relate('us-west-1-prod');

    #
    # returns:
    # {
    #    common => [
    #                './us.yml',
    #                './us-west.yml',
    #                './us-west-1.yml',
    #              ],
    #    unique => [
    #                './us-west-1-preprod.yml',
    #              ],
    # }
    #

Callers can use this to treat the common files differently from the unique
files.  The CI pipelines use this to properly craft the Concourse git
resource watch paths.


=head2 potential_environment_files()

Assemble the list of candidate YAML files that comprise this environment.
Under the hood, this is just a call to C<relate()> with no environment,
which forces everything into the I<unique> set.  See C<relate()> for more
details.

If the C<PREVIOUS_ENV> environment variable is set, it is interpreted as the
name of the Genesis environment that preceeds this one in the piepline.
Files that this environment shares with that one (per the semantics of
C<relate>) will be taken from the C<.genesis/cached/$env> directory, instead
of the top-level.


=head2 actual_environment_files()

Return C<potential_environment_files>, filtered to include only the files
that actually reside on-disk.  Suitable for merging with Spruce!


=head2 kit_files

Returns the source YAML files from the environment's kit, based on the
selected features.  This is a very thin wrapper around Genesis::Kit's
C<source_yaml_files> method.


=head2 params()

Merges the environment files (see C<environment_files>), without evaluating
Spruce operators (i.e. C<--skip-eval>), and then returns the resulting
hashref structure.

This structure can then be interrogated by things like C<defines> and
C<lookup> to retrieve metadata about the environment.

This call is I<memoized>; calling it multiple times on the same object will
not incur additional merges.  If cache coherency is a concern, recreate your
object.


=head2 defines($key)

Returns true of this environment has defined C<$key> in any of its
constituent YAML files.  Multi-level keys should be specified in
dot-notation:

    if ($env->defines('params.something')) {
      # ...
    }

If you need the actual I<values> that the defined key is set to, look at
C<lookup>.


=head2 lookup($key, [$default])

Retrieve the value an environment has set for C<$key> (in any of its files),
or C<$default> if the key hasn't been defined.  If C<$key> is an array
reference, each key in the array is checked until it finds one that has been
defined.  If called in a list context (including inside a function call), it
will return a list of the value, and the matching key (which will be undefined
if no key is found)

    my $v = $env->lookup('kit.version', 'latest');
    print "using version $v...\n";

To get just the found value when calling within a function, wrap the call with
`scalar(...)`:

    debug "Kit name: %s", scalar($env->lookup('kit.name'));

This can be combined with calls to C<defines> to avoid having to specify a
default value when you don't want to:

    if ($env->defines('params.optional')) {
      my $something = $env->lookup('params.optional');
      print "optionally doing $something\n";
    }

Note that you can retrieve complex structures like YAML maps (Perl hashrefs)
and lists (arrayrefs) by not specifying a leaf node:

    my $kit = $env->lookup('kit');
    print "Using $kit->{name}/$kit->{version}\n";

This can be preferable to calling C<lookup> multiple times, and is currently
the only way to pull data out of a list.

If the key is an empty string, it will return the entire data structure.

If default is a code reference, it will be executed and the result will be
returned if and only if the default value is needed (ie no matching key is
found). This allows for short circuit evaluation of the default.

=head2 manifest_lookup($key, [$default])

Similar to C<lookup>, but uses the merged manifest as the source of the data.

=head2 last_deployed_lookup($key, [$default])

Similar to C<lookup>, but uses the last deployed (redacted) manifest for the
environment.  Raises an error if there hasn't been a cached manifest for the
environment.

=head2 exodus_lookup($key, [$default])

Similar to C<lookup>, but uses the exodus data stored in Vault for the
environment.  Raises an error if there hasn't been a successful deployment for
the environment.

=head2 features()

Returns a list (not an arrayref) of the features that this environment has
specified in its C<kit.features> parameter.

=head2 has_feature($x)

Returns true if this environment has activated the feature C<$x> by way of
C<kit.features>.

=head2 use_create_env()

Returns true if this environment (based on its activated features) needs to
be deployed via a C<bosh create-env> run, instead of the more normal C<bosh
deploy>.


=head2 manifest_lookup($key, $default)

Like C<lookup()>, except that it considers the entire, unredacted deployment
manifest for the environment.  You must have set a cloud-config via
C<use_cloud_config()> before you call this method.


=head2 manifest(%opts)

Generates the complete manifest for this environment, merging in the
environment definition files with the kit manifest fragments for the
selected features.  The manifest will be cached, effectively memoizing this
method.  You must have set a cloud-config via C<use_cloud_config()> before
you call this method.

The following options are recognized:

=over

=item redact

Redact the manifest, obscuring all secrets that would normally have been
populated from the Genesis Vault.  Redacted and unredacted versions of the
manifest will be memoized separately, to avoid cache coherence issues.

=item prune

Whether or not to prune auxilliary top-level keys from the generated
manifest (redacted or otherwise).  BOSH requires the manifest to be pruned
before it will process it for deployment, since Genesis has to merge in the
active BOSH cloud-config for things like the Spruce (( static_ips ... ))
operator.

You may want to set prune => 0 to get the full manifest, for debugging.

By default, the manifest will be pruned.

=back


=head2 write_manifest($file, %opts)

Write the deployment manifest (as generated by C<manifest>) to the given
C<$file>.  This method takes the same options as the C<manifest> method that
it wraps.  You must have set a cloud-config via C<use_cloud_config()> before
you call this method.

=head2 cached_manifest_info

Returns the path, existance (boolean), and SHA-1 checksum for the cached
redacted deployment manifest.  The SHA-1 sum is undefined if the file does not
exist.

=head2 exodus()

Retrieves the I<Exodus> data that the kit compiled for this environment, and
flatten it so that it can be stuffed into the Genesis Vault.


=head2 bosh_target()

Determine the alias of the BOSH director that Genesis would use to deploy
this environment.  It consults the following, in order:

=over

=item 1.

The C<$GENESIS_BOSH_ENVIRONMENT> variable.

=item 2.

The C<params.bosh> parameter

=item 3.

The C<params.env> parameter

=back

If none of these pan out, this method will die with a suitable error.

Note that if this environment is to be deployed via C<bosh create-env>, this
method will always return C<undef> immediately.

=head2 has_hook($hook)

Returns true if the kit used by this environment has the named hook.

=head2 run_hook($hook, %options)

Runs the kit hook named C<$hook> against this environment, with the given
options.  See C<Genesis::Kit::run_hook> for more details.

=head2 deploy(%opts)

Deploy this environment, to its BOSH director.  If successful, a redacted
copy of the manifest will be saved in C<.genesis/manifests>.  The I<Exodus>
data for the environment will also be extracted and placed in the Genesis
Vault at that point.

The following options are recognized (for non-create-env deployments only):

=over

=item redact

Do (or don't) redact the output of the C<bosh deploy> command.

=item fix

Sets the C<--fix> flag in the call to C<bosh deploy>.

=item fix-releases

Sets the C<--fix-releases> flag in the call to C<bosh deploy>.

=item recreate

Sets the C<--recreate> flag in the call to C<bosh deploy>.

=item dry-run

Sets the C<--dry-run> flag in the call to C<bosh deploy>.

=item skip-drain => [ ... ]

Sets the C<--skip-drain> flag multiple times, once for each value in the
given arrayref.

=item canaries => ...

Sets the C<--canaries> flag to the given value.

=item max-in-flight => ...

Sets the C<--max-in-flight> flag to the given value.

=back


=head2 add_secrets(%opts)

Adds secrets to the Genesis Vault.  This generally invokes the "secrets"
hook, but can fallback to legacy kit.yml behavior.

The following options are recognized:

=over

=item recreate

This is a recreate, and all credentials should be recreated, not just the
missing one.

=back


=head2 check_secrets()

Checks the Genesis Vault for secrets that the kit defines, but that are not
present.  This runs the "secrets" hook, but also handles legacy kit.yml
behavior.


=head2 rotate_secrets(%opts)

Rotates all non-fixed secrets stored in the Genesis Vault.

The following options are recognized:

=over

=item force

If set to true, all non-fixed credentials will be rotated, not just the
missing ones (which is the default behavior for some reason).

=back

=cut
# vim: fdm=marker:foldlevel=1:noet
