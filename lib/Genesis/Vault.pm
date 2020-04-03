package Genesis::Vault;
use strict;
use warnings;

use Genesis;
use Genesis::UI;
use JSON::PP qw/decode_json/;

### Class Variables {{{
my (@all_vaults, $default_vault, $current_vault);
# }}}

### Class Methods {{{

# new - raw instantiation of a vault object {{{
sub new {
	my ($class, $url, $name, $verify) = @_;
	return bless({
			url    => $url,
			name   => $name,
			verify => $verify ? 1 : 0, # Cleans out JSON::Boolean types
			id     => sprintf("%s-%06d",$name,rand(1000000))
		}, $class);
}

# }}}
# target - builder for vault based on locally available vaults {{{
sub target {
	my ($class,$target,%opts) = @_;

	$opts{default_vault} ||= $class->default;

	my $url;
	if ($target) {
		($url, my @targets) = _get_targets($target);
		if (scalar(@targets) <1) {
			bail "#R{[ERROR]} Safe target \"#M{%s}\" not found.  Please create it\n".
					 "and authorize against it before re-attempting this command.",
					 $target;
		}
		if (scalar(@targets) >1) {
			bail "#R{[ERROR]} Multiple safe targets use url #M{%s}:\n%s\n".
					 "\nYour ~/.saferc file cannot have more than one target for the given url.  Please".
					 "remove any duplicate targets before re-attempting this command.",
					 $url, join("", map {" - #C{$_}\n"} @targets);
		}
	} else {

		die_unless_controlling_terminal;

		my $w = (sort {$b<=>$a} map {length($_->{name})} $class->find)[0];

		my (%uses,@labels,@choices);
		$uses{$_->{url}}++ for $class->find;
		for ($class->find) {
			next unless $uses{$_->{url}} == 1;
			push(@choices, $_->{url});
			push(@labels, [csprintf(
			"#%s{%-*.*s}   #R{%-10.10s} #%s{%s}",
			  $_->{name} eq $opts{default_vault}->{name} ? "G" : "-",
			     $w, $w, $_->{name},
			                  $_->{url} =~ /^https/ ? ($_->{verify} ? "" : "(noverify)") : "(insecure)",
			                             $_->{name} eq $opts{default_vault}->{name} ? "Y" : "-",
			                                $_->{url}
			),$_->{name}]);
		}

		my $msg = csprintf("#u{Select Vault:}\n");
		my @invalid_urls = grep {$uses{$_} > 1} keys(%uses);

		if (scalar(@invalid_urls)) {
			$msg .= csprintf("\n".
				"#Y{Note:} One or more vault targets have been omitted because they are alias for\n".
				"      the same URL, which is incompatible with Genesis's distributed model.\n".
				"      If you need one of the omitted targets, please ensure there is only one\n".
				"      target alias that uses its URL.\n");
		}

		bail("#R{[ERROR]} There are no valid vault targets found on this system.")
			unless scalar(@choices);

		$url = prompt_for_choice(
			$msg,
			\@choices,
			$uses{$opts{default_vault}->{url}} == 1 ? $opts{default_vault}->{url} : undef,
			\@labels
		)
	}

	my $vault = ($class->find(url => $url))[0];
	return $vault->connect_and_validate()
}

# }}}
# attach - builder for vault based on loaded environment {{{
sub attach {
	my ($class, $url, $insecure) = @_;

	# Allow vault target and insecure to be specified by ENV variables.
	$url = $ENV{substr($url,1)} if substr($url,0,1) eq '$';
	$insecure = $ENV{substr($insecure,1)} if substr($insecure,0,1) eq '$';

	bail "#R{[ERROR]} No vault target specified"
		unless $url;
	bail "#R{[ERROR]} Expecting vault target '$url' to be a url"
		unless _target_is_url($url);

	($url, my @targets) = _get_targets($url);
	if (scalar(@targets) <1) {
		bail "#R{[ERROR]} Safe target for #M{%s} not found.  Please run\n\n".
				 "  #C{safe target <name> \"%s\"%s\n\n".
				 "then authenticate against it using the correct auth method before\n".
				 "re-attempting this command.",
				 $url, $url,($insecure?" -k":"");
	}
	if (scalar(@targets) >1) {
		bail "#R{[ERROR]} Multiple safe targets found for #M{%s}:\n%s\n".
				 "\nYour ~/.saferc file cannot have more than one target for the given url.\n" .
				 "Please remove any duplicate targets before re-attempting this command.",
				 $url, join("", map {" - #C{$_}\n"} @targets);
	}

	my $vault = $class->new($url, $targets[0], !$insecure);
	return $vault->connect_and_validate;
}

# }}}
# rebind - builder for rebinding to a previously selected vault (for callbacks) {{{
sub rebind {
	# Special builder with less checking for callback support
	my ($class) = @_;

	bail("Cannot rebind to vault in callback due to missing environment variables!")
		unless $ENV{GENESIS_TARGET_VAULT};

	my $vault;
	if (is_valid_uri($ENV{GENESIS_TARGET_VAULT})) {
		$vault = ($class->find(url => $ENV{GENESIS_TARGET_VAULT}))[0];
		bail("Cannot rebind to vault at address '$ENV{GENESIS_TARGET_VAULT}` - not found in .saferc")
			unless $vault;
		trace "Rebinding to $ENV{GENESIS_TARGET_VAULT}: Matches %s", $vault && $vault->{name} || "<undef>";
	} else {
		# Check if its a named vault and if it matches the default (legacy mode)
		if ($ENV{GENESIS_TARGET_VAULT} eq $class->default->{name}) {
			$vault = $class->default()->ref_by_name();
			trace "Rebinding to default vault `$ENV{GENESIS_TARGET_VAULT}` (legacy mode)";
		}
	}
	return unless $vault;
	return $vault->set_as_current;
}

# }}}
# find - return vaults that match filter (defaults to all) {{{
sub find {
	my ($class, %filter) = @_;
	@all_vaults = (
		map {Genesis::Vault->new($_->{url},$_->{name},$_->{verify})}
		sort {$a->{name} cmp $b->{name}}
		@{ read_json_from(run({env => {VAULT_ADDR => "", SAFE_TARGET => ""}}, "safe targets --json")) }
	) unless @all_vaults;
	my @matches = @all_vaults;
	for my $quality (keys %filter) {
		@matches = grep {$_->{$quality} eq $filter{$quality}} @matches;
	}
	return @matches;
}

# }}}
# find_by_target - return all vaults matching url associated with specified target alias or url {{{
sub find_by_target {
	my ($class, $target) = @_;
	my ($url, @aliases) = _get_targets($target);
	return map {$class->find(name => $_)} @aliases;
}

# }}}
# default - return the default vault (targeted by system) {{{
sub default {
	unless ($default_vault) {
		my $json = read_json_from(run({env => {VAULT_ADDR => "", SAFE_TARGET => ""}},"safe target --json"));
		$default_vault = (Genesis::Vault->find(name => $json->{name}))[0];
	}
	return $default_vault;
}

# }}}
# current - return the last vault returned by attach, target, or rebind {{{
sub current {
	return $current_vault
}

# }}}
# clear_all - clear all cached data {{{
sub clear_all {
	for (@all_vaults) {
		delete($_->{_env});
	}
	@all_vaults=();
	$default_vault=undef;
	$current_vault=undef;
	return $_[0]; # chaining Genesis::Vault
}
# }}}
# }}}

### Instance Methods {{{

# public accessors: url, name, verify, tls {{{
sub url     { $_[0]->{url};    }
sub name    { $_[0]->{name};   }
sub verify  { $_[0]->{verify}; }
sub tls     { $_[0]->{url} =~ "^https://"; }

#}}}
# connect_and_validate - connect to the vault and validate that its connected {{{
sub connect_and_validate {
	my ($self) = @_;
	unless ($self->is_current) {
		printf STDERR csprintf("\n#yi{Verifying availability of selected vault...}")
			unless in_callback || under_test;
		my $status = $self->status;
		error("#%s{%s}\n", $status eq "ok"?"G":"R", $status)
			unless in_callback || under_test;
		debug "Vault status: $status";
		bail("#R{[ERROR]} Could not connect to vault: status is $status") unless $status eq "ok";
	}
	return $self->set_as_current;
}

# }}}
# query - make safe calls against this vault {{{
sub query {
	my $self = shift;
	my $opts = ref($_[0]) eq "HASH" ? shift : {};
	my @cmd = @_;
	unshift(@cmd, 'safe') unless $cmd[0] eq 'safe';
	$opts->{env} ||= {};
	$opts->{env}{DEBUG} = "";                 # safe DEBUG is disruptive
	$opts->{env}{SAFE_TARGET} = $self->ref; # set the safe target
	return run($opts, @cmd);
}

# }}}
# get - get a key or all keys under for a given path {{{
sub get {
	my ($self, $path, $key) = @_;
	if (defined($key)) {
		my ($out,$rc) = $self->query('get', "$path:$key");
		return $out if $rc == 0;
		debug(
			"#R{[ERROR]} Could not read #C{%s:%s} from vault at #M{%s}",
			$path, $key,$self->{url}
		);
		return undef;
	}
	my ($json,$rc,$err) = read_json_from($self->query('export', $path));
	if ($rc || $err) {
		debug(
			"#R{[ERROR]} Could not read all key/value pairs from #C{%s} in vault at #M{%s}:%s\nexit code: %s",
			$path,$self->{url},$err,$rc
		);
		return {};
	}
	$path =~ s/^\///; # Trim leading / as safe doesn't honour it
	return $json->{$path} if (ref($json) eq 'HASH') && defined($json->{$path});

	# Safe 1.1.0 is backwards compatible, but leaving this in for futureproofing
	if (ref($json) eq "ARRAY" and scalar(@$json) == 1) {
		if ($json->[0]{export_version}||0 == 2) {
			return $json->[0]{data}{$path}{versions}[-1]{value};
		}
	}
	bail "Safe version incompatibility - cannot export path $path";

}

# }}}
# set - write a secret to the vault (prompts for value if not given) {{{
sub set {
	my ($self, $path, $key, $value) = @_;
	if (defined($value)) {
		my ($out,$rc) = $self->query('set', $path, "${key}=${value}");
		bail(
			"#R{[ERROR]} Could not write #C{%s:%s} to vault at #M{%s}:\n%s",
			$path, $key,$self->{url},$out
		) unless $rc == 0;
		return $value;
	} else {
		# Interactive - you must supply the prompt before hand
		die_unless_controlling_terminal;
		my ($out,$rc) = $self->query({interactive => 1},'set', $path, $key);
		bail(
			"#R{[ERROR]} Could not write #C{%s:%s} to vault at #M{%s}",
			$path, $key,$self->{url}
		) unless $rc == 0;
		return $self->get($path,$key);
	}
}

# }}}
# has - return true if vault has given key {{{
sub has {
	my ($self, $path, $key) = @_;
	return $self->query({ passfail => 1 }, 'exists', defined($key) ? "$path:$key" : $path);
}

# }}}
# paths - return all paths found under the given prefixes (or all if no prefix given) {{{
sub paths {
	my ($self, @prefixes) = @_;

	# TODO: Once safe stops returning invalid pathts, the following will work:
	# return lines($self->query('paths', @prefixes));
	# instead, we have to do this less efficient routine
	return lines($self->query('paths')) unless scalar(@prefixes);

	my @all_paths=();
	for my $prefix (@prefixes) {
		my @paths = lines($self->query('paths', $prefix));
		if (scalar(@paths) == 1 && $paths[0] eq $prefix) {
			next unless $self->has($prefix);
		}
		push(@all_paths, @paths);
	}
	return @all_paths;
}

# }}}
# keys - return all path:key pairs under the given prefixes (or all if no prefix given) {{{
sub keys {
	my ($self, @prefixes) = @_;
	return lines($self->query('paths','--keys')) unless scalar(@prefixes);

	my @all_paths=();
	for my $prefix (@prefixes) {
		my @paths = lines($self->query('paths', '--keys', $prefix));
		next if (scalar(@paths) == 1 && $paths[0] eq $prefix);
		push(@all_paths, @paths);
	}
	return @all_paths;
}

# }}}
# status - returns status of vault: sealed, unreachable, invalid authentication or ok {{{
sub status {
	my $self = shift;
	my $secrets_mount = $ENV{GENESIS_SECRETS_MOUNT} || "/secret/";

	# See if the url is reachable to start with
	$self->url =~ qr(^http(s?)://(.*?)(?::([0-9]*))?$) or
		bail("Invalid vault target URL #C{%s}: expecting http(s)://ip-or-domain(:port)", $self->url);
	my $ip = $2;
	my $port = $3 || ($1 eq "s" ? 443 : 80);
	return "unreachable" unless tcp_listening($ip,$port);

	return "unauthenticated" if $self->token eq "";
	my ($out,$rc) = $self->query({stderr => "&1"}, "vault", "status");
	if ($rc != 0) {
		$out =~ /exit status ([0-9])/;
		return "sealed" if $1 == 2;
		return "unreachable";
	}
	return "uninitialized" unless $self->has($secrets_mount.'handshake');
	return "ok"
}

# }}}
# env - return the environment variables needed to directly access the vault {{{
sub env {
	my $self = shift;
	unless (defined $self->{_env}) {
		$self->{_env} = read_json_from(
			run({
					stderr =>'/dev/null',
					env => {SAFE_TARGET => $self->ref }
				},'safe', 'env', '--json')
		);
		$self->{_env}{VAULT_SKIP_VERIFY} ||= "";
		# die on missing VAULT_ADDR env?
	}
	return $self->{_env};
}

# }}}
# token - the authentication token for the active vault {{{
sub token {
	my $self = shift;
	return $self->env->{VAULT_TOKEN};
}

# }}}
# ref - the reference to be used when identifying the vault (name or url) {{{
sub ref {
	my $self = shift;
	return $self->{$self->{ref_by} || 'url'};
}

# }}}
# ref_by_name - use the name of the vault as its reference (legacy mode) {{{
sub ref_by_name {
	$_[0]->{ref_by} = 'name';
	$_[0];
}

# }}}
# set_as_current - set this vault as the current Genesis vault {{{
sub set_as_current {
	$current_vault = shift;
}
sub is_current {
  $current_vault && $current_vault->{id} eq $_[0]->{id};
}

# }}}
# process_kit_secret_plans - perform actions on the kit secrets: add,recreate,renew,check,remove {{{
sub process_kit_secret_plans {
	my ($self, $action, $env, $update, %opts) = @_;

	my $process_failed = $action =~ s/^(recreate|renew|remove)-failed$/$1/;
	bug("#R{[Error]} Unknown action '$action' for processing kit secrets")
		if ($action !~ /^(add|recreate|renew|remove)$/);

	$update->('wait', msg => "Parsing kit secrets descriptions");
	my @plans = parse_kit_secret_plans(
		$env->dereferenced_kit_metadata,
		[$env->features],
		root_ca_path => $env->root_ca_path,
		%opts)
	;

	my @errors = map {my ($p,$t,$m) = describe_kit_secret_plan(%$_); sprintf "%s: %s", $p, $m} grep {$_->{type} eq 'error'} @plans;
	$update->('wait-done', result => (@errors ? 'error' : 'ok'), msg => join("\n", @errors));
	return if (@errors);

	if ($process_failed) {
		@plans = $self->_get_failed_secret_plans($action, $env, $update, @plans);
		return $update->('empty', msg => sprintf "No failed secrets found%s.", $opts{filter} ? " matching provided filter" : "")
			unless scalar(@plans);
	}
	#Filter out any path that has no plan - only x509 has support for renew
	#TODO: make this generalized if other things are supported in the future
	@plans = grep {$_->{type} eq 'x509'} @plans if $action eq 'renew';
	return $update->('empty') unless scalar(@plans);

	if ($action =~ /^(remove|recreate|renew)$/ && !$opts{'no-prompt'}) {
		(my $actioned = $action) =~ s/e?$/ed/;
		my $permission = $update->('prompt',
			class => 'warning',
			msg => "The following secrets will be ${actioned}:\n  ". join("\n  ",
				map {bullet $_, inline => 1}
				map {_get_plan_paths($_)}
				@plans
			),
			prompt => "Type 'yes' to $action these secrets");
		return $update->('abort', msg => "\nAborted!\n")
			if $permission ne 'yes';
	}

	my ($result, $err, $idx);
	$update->('init', total => scalar(@plans));
	if ($opts{batch}) {
		bug "Batch processing of secret plans not supported yet!";
		my @command = _generate_secret_command($action, $env->secrets_base, 1, %$_);
	} else {
		for (@plans) {
			my ($path, $label, $details) = describe_kit_secret_plan(%$_);
			$update->('start-item', path => $path, label => $label, details => $details);
			my $now_t = Time::Piece->new(); # To prevent clock jitter
			my @command = _generate_secret_command($action, $env->secrets_base, 0, %$_);
			my ($out, $rc) = $self->query(@command);

			if ($out =~ /refusing to .* as it is already present/) {
				$update->('done-item', result => 'skipped')
			} elsif ( $action eq 'renew' && $out =~ /Renewed x509 cert.*expiry set to (.*)$/) {
				my $expires = $1;
				eval {
					(my $exp_gmt = $1) =~ s/UTC/GMT/;
					my $expires_t = Time::Piece->strptime($exp_gmt, "%b %d %Y %H:%M %Z");
					my $days = sprintf("%.0f",($expires_t - $now_t)->days());
					$update->('done-item', result => 'ok', msg => _checkbox(1)."Expiry updated to $expires ($days days)");
				};
				$update->('done-item', result => 'ok', msg => "Expiry updated to $expires") if $@;
			} elsif (!$out) {
				$update->('done-item', result => 'ok')
			} else {
				$update->('done-item', result => 'error', msg => $out);
			}
			last if ($rc);
		}
	}
	return $update->('completed');
}

# }}}
# validate_kit_secrets - validate kit secrets {{{
sub validate_kit_secrets {
	my ($self, $action, $env, $update, %opts) = @_;
	bug("#R{[Error]} Unknown action '$action' for checking kit secrets")
		if ($action !~ /^(check|validate)$/);

	$update->('wait', msg => "Parsing kit secrets descriptions");
	my @plans = parse_kit_secret_plans(
		$env->dereferenced_kit_metadata,
		[$env->features],
		root_ca_path => $env->root_ca_path,
		%opts);

	my @errors = map {my ($p,$t,$m) = describe_kit_secret_plan(%$_); sprintf "%s: %s", $p, $m} grep {$_->{type} eq 'error'} @plans;
	$update->('wait-done', result => (@errors ? 'error' : 'ok'), msg => join("\n", @errors));
	return if (@errors);

	$update->('wait', msg => "Retrieving all existing secrets");
	my ($secret_contents,$err) =$self->all_secrets_for($env);
	$update->('wait-done', result => ($err ? 'error' : 'ok'), msg => $err);
	return if $err;

	$update->('init', total => scalar(@plans));
	for my $plan (@plans) {
		my ($path, $label, $details) = describe_kit_secret_plan(%$plan);
		$update->('start-item', path => $path, label => $label, details => $details);
		my ($result, $msg) = _validate_kit_secret($action,$plan,$secret_contents,$env->secrets_base,\@plans);
		$update->('done-item', result => $result, msg => $msg);
	}
	return $update->('completed');
}

# }}}
# all_secrets_under - return hash for all secrets under the given path {{{
sub all_secrets_for {
	my ($self, $env) = @_;

	my ($secret_contents,$err);
	my $root_path = $env->secrets_base;
	debug "Turning off debug and trace output while retrieving secrets";
	local $ENV{GENESIS_TRACE}='';
	local $ENV{GENESIS_DEBUG}='';
	my @cmd = ('export', $env->secrets_base);
	my $root_ca_path = $env->root_ca_path;
	push @cmd, $root_ca_path if $root_ca_path;
	my $raw_secrets = $self->query(@cmd);
	return ({}, "Root CA certificate not found")
		if $raw_secrets =~ /^!! no secret exists at path \`$root_ca_path\`/;
	return ({})
		if $raw_secrets =~ /^!! no secret exists at path/;
	eval {
		$secret_contents = decode_json($raw_secrets);
	};
	$err = "Could not retrieve existing secrets for $root_path" if $@;
	return($secret_contents, $err);
}

# }}}
# }}}

### Private Methods {{{
# _expected_kit_secret_keys - list keys expected for a given kit secret {{{
sub _expected_kit_secret_keys {
	my (%plan) = @_;
	my @keys;
	my $type = $plan{type};
	if ($type eq 'x509') {
		@keys = qw(certificate combined key);
		push(@keys, qw(crl serial)) if $plan{is_ca};
	} elsif ($type eq 'rsa') {
		@keys = qw(private public);
	} elsif ($type eq 'ssh') {
		@keys = qw(private public fingerprint);
	} elsif ($type eq 'dhparam') {
		@keys = qw(dhparam-pem);
	} elsif ($type eq 'random') {
		my (undef,$key) = split(":",$plan{path});
		@keys = ($key);
		push(@keys, $plan{destination} || "$key-".$plan{format})
			if $plan{format};
	}
	return @keys;
}

# }}}
# _get_failed_secret_plans - list the plans for failed secrets {{{
sub _get_failed_secret_plans {
	my ($self, $scope, $env, $update, @plans) = @_;
	$update->('wait', msg => "Retrieving all existing secrets");
	my ($secret_contents,$err) =$self->all_secrets_for($env);
	$update->('wait-done', result => ($err ? 'error' : 'ok'), msg => $err);
	return () if $err;

	my @failed;
	my ($total, $idx) = (scalar(@plans), 0);
	$update->('init', action => "Checking for failed".($scope eq 'recreate' ? ' or missing' : '')." secrets", total => scalar(@plans));
	for my $plan (@plans) {
		my ($path, $label, $details) = describe_kit_secret_plan(%$plan);
		$update->('start-item', path => $path, label => $label, details => $details);
		my ($result, $msg) = _validate_kit_secret('validate',$plan,$secret_contents,$env->secrets_base, \@plans);
		if ($result eq 'error' || ($result eq 'missing' && $scope eq 'recreate')) {
			$update->('done-item', result => $result, msg => $msg) ;
			push @failed, $plan;
		} else {
			$update->('done-item', result => 'ok')
		}
	}
	return @failed;
}
# }}}
# }}}

### Public helper functions {{{

# parse_kit_secret_plans - get the list of secrets specified by the kit {{{
sub parse_kit_secret_plans {
  my ($metadata, $features, %opts) = @_;
	trace "Parsing plans for kit secrets";
	my $plans = _get_kit_secrets($metadata, $features, %opts);

	# Sort the plans in order of application (check for cyclical ca relations)
	my $groups = {};
	push(@{$groups->{$plans->{$_}{type}} ||= []}, $_) for (sort(CORE::keys(%$plans)));

	my @ordered_plans = _process_x509_plans(
		$plans,
		delete($groups->{x509}),
		$opts{root_ca_path},
		$opts{validate});

	# Add in all the other types that don't require prerequesites
	for my $type (sort(CORE::keys %$groups)) {
		for my $path (sort @{$groups->{$type}}) {
			my $ok = 1;
			if ($opts{validate}) {
				my $validate_sub = "_validate_${type}_plan";
				$ok = (\&{$validate_sub})->($plans,$path,\@ordered_plans) if exists(&{$validate_sub});
			}
			push @ordered_plans, $plans->{$path} if $ok;
		}
	}

	if ($opts{filter}) {
		$opts{filter} =~ '^((!)?/)?(.*?)(/(i)?)?$';
		my ($match,$pattern,$reopt) = (($2 || '') ne '!', $3, ($5 || ''));
		$pattern = "^$pattern\$" if (!$1 || !$4);
		my $re; eval "\$re = qr/\$pattern/$reopt";
		@ordered_plans = grep {$match ? $_->{path} =~ $re : $_->{path} !~ $re} (@ordered_plans);
	}
	trace "Completed parsing plans for kit secrets";
	return @ordered_plans;
}

# }}}
# describe_kit_secret_plan - get a printable slug for the a kit secret plan {{{
sub describe_kit_secret_plan {
	my (%plan) = @_;
	my ($path,$type,@features);
	$path = $plan{path};
	if ($plan{type} eq 'x509') {
		$type = "X509 certificate";
		@features = (
			$plan{is_ca} ? 'CA' : undef,
			$plan{self_signed}
			  ? ($plan{self_signed} == 2 ? 'explicitly self-signed' : 'self-signed')
				: ($plan{signed_by} ? "signed by '$plan{signed_by}'" : undef )
		);
	} elsif ($plan{type} eq 'random') {
		$type = "random password";
		@features = (
			$plan{size} . ' bytes',
			$plan{fixed} ? 'fixed' : undef
		)
	} elsif ($plan{type} eq 'dhparams') {
		$type = "Diffie-Hellman key exchange parameters";
		@features = (
			$plan{size} . ' bits',
			$plan{fixed} ? 'fixed' : undef
		);
	} elsif ($plan{type} =~ /^(ssh|rsa)$/) {
		$type = uc($plan{type})." public/private keypair";
		@features = (
			$plan{size} . ' bits',
			$plan{fixed} ? 'fixed' : undef
		);
	} elsif ($plan{type} eq 'error') {
		$type = "ERROR";
		@features = (
			$plan{error},
		);
		debug("Error encountered in secret plan $path:");
		dump_var plan => \%plan;
	} else {
		$type = "ERROR";
		@features = (
			"Unsupported secret type '%s'"
		);
	}
	return ($path,$type,join (", ", grep {$_} @features));
}

# }}}
# }}}

### Private helper functions {{{

# _target_is_url - determine if target is in valid URL form {{{
sub _target_is_url {
	my $target = lc(shift);
	return 0 unless $target =~ qr(^https?://([^:/]+)(?::([0-9]+))?$);
	return 0 if $2 && $2 > 65535;
	my @comp = split(/\./, $1);
	return 1 if scalar(@comp) == 4 && scalar(grep {$_ =~ /^[0-9]+$/ && $_ >=0 && $_ < 256} @comp) == 4;
	return 1 if scalar(grep {$_ !~ /[a-z0-9]([-_0-9a-z]*[a-z0-9])*/} @comp) == 0;
	return 0;
}

# }}}
# _get_targets - find all matching safe targets for the provided name or url {{{
sub _get_targets {
	my $target = shift;
	unless (_target_is_url($target)) {
		my $target_vault = (Genesis::Vault->find(name => $target))[0];
		return (undef) unless $target_vault;
		$target = $target_vault->{url};
	}
	my @names = map {$_->{name}} Genesis::Vault->find(url => $target);
	return ($target, @names);
}

# }}}
# _get_kit_secrets - get the raw secrets from the kit.yml file {{{
sub _get_kit_secrets {
	my ($meta, $features, %opts) = @_;

	my $plans = {};
	for my $feature ('base', @{$features || []}) {
		if ($meta->{certificates}{$feature}) {
			for my $path (CORE::keys %{ $meta->{certificates}{$feature} }) {
				if ($path =~ ':') {
					$plans->{$path} = {type=>'error', error=>"Bad Request:\n- Path cannot contain colons"};
					next;
				}
				my $data = $meta->{certificates}{$feature}{$path};
				if (CORE::ref($data) eq 'HASH') {
					for my $k (CORE::keys %$data) {
						my $ext_path = "$path/$k";
						$plans->{$ext_path} = $data->{$k};
						if (CORE::ref($plans->{$ext_path}) eq 'HASH') {
							$plans->{$ext_path}{type} = "x509";
							$plans->{$ext_path}{base_path} = $path;
						} else {
							$plans->{$ext_path} = {type => 'error', error => "Badly formed x509 request:\nExpecting hash map, got '$plans->{$ext_path}'"};
						}
						# In-the-wild POC conflict fix for cf-genesis-kit v1.8.0-v1.10.x
						$plans->{$ext_path}{signed_by} = "application/certs/ca"
							if ($plans->{$ext_path}{signed_by} || '') eq "base.application/certs.ca";
					}
				} else {
					$plans->{$path} = {type => 'error', error => "Badly formed x509 request:\n- expecting certificate specification in the form of a hash map"};
				}
			}
		}
		if ($meta->{credentials}{$feature}) {
			for my $path (CORE::keys %{ $meta->{credentials}{$feature} }) {
				if ($path =~ ':') {
					$plans->{$path} = {type=>'error', error=>"Bad credential request:\n- Path cannot contain colons"};
					next;
				}
				my $data = $meta->{credentials}{$feature}{$path};
				if (CORE::ref($data) eq "HASH") {
					for my $k (CORE::keys %$data) {
						if ($k =~ ':') {
							$plans->{"$path:$k"} = {type=>'error', error=>"Bad credential request:\n- Key cannot contain colons"};
							next;
						}
						my $cmd = $data->{$k};
						if ($cmd =~ m/^random\s+(\d+)(\s+fmt\s+(\S+)(\s+at\s+(\S+))?)?(\s+allowed-chars\s+(\S+))?(\s+fixed)?$/) {
							$plans->{"$path:$k"} = {
								type=> 'random',
								size => $1,
								format => $3,
								destination => $5,
								valid_chars => $7,
								fixed => (!!$8)
							};
						} else {
							$plans->{"$path:$k"} = {type => "error", error => "Bad crecential request:\n- Bad generate-password format '$cmd'"};
						}
					}
				} elsif ($data =~ m/^(ssh|rsa)\s+(\d+)(\s+fixed)?$/) {
					$plans->{$path} = {type => $1, size=> $2, fixed => (!!$3) };
				} elsif ($data =~ m/^dhparams?\s+(\d+)(\s+fixed)?$/) {
					$plans->{$path} = {type => 'dhparams', size => $1, fixed => (!!$2) }
				} elsif ($data =~ m/^random .?$/) {
					$plans->{$path} = {type => 'error', error => "Bad credential request:\n- Random password request for a path must be specified per key in a hashmap"};
				} else {
					$plans->{$path} = {type => 'error', error => "Bad credential request:\n- Unrecognized request '$data'"};
				}
			}
		}
	}
	$plans->{$_}{path} = $_ for CORE::keys %$plans;
	return $plans;
}

# }}}
# _generate_secret_command - create safe command list that can be run standalone or as part of a batch {{{
sub _generate_secret_command {
	my ($action,$root_path, $batch, %plan) = @_;
	my @cmd;
	if ($action eq 'remove') {
		@cmd = ('rm', '-f', $root_path.$plan{path});
		if ($plan{type} eq 'random' && $plan{format}) {
			my ($secret_path,$secret_key) = split(":", $plan{path},2);
			my $fmt_path = sprintf("%s:%s", $root_path.$secret_path, $plan{destination} ? $plan{destination} : $secret_key.'-'.$plan{format});
			push @cmd, '--', 'rm', '-f', $fmt_path;
		}
	} elsif ($plan{type} eq 'x509') {
		my %action_map = (add      => 'issue',
			                recreate => 'issue',
			                renew    => 'renew');
		my @names = @{$plan{names} || []};
		push(@names, sprintf("ca.n%09d.%s", rand(1000000000),$plan{base_path})) if $plan{is_ca} && ! scalar(@names);
		@cmd = (
			'x509',
			$action_map{$action},
			$root_path.$plan{path},
			'--ttl', $plan{valid_for} || ($plan{is_ca} ? '10y' : '1y'),
		);
		push(@cmd, '--signed-by', ($plan{signed_by_abs_path} ? '' : $root_path).$plan{signed_by}) if $plan{signed_by};
		if ($action_map{$action} eq 'issue') {
			push(@cmd, '--ca') if $plan{is_ca};
			push(@cmd, '--name', $_) for (@names);
			if (CORE::ref($plan{usage}) eq 'ARRAY') {
				push(@cmd, '--key-usage', $_) for (@{$plan{usage}} ? @{$plan{usage}} : qw/no/);
			}
		}
	} elsif ($action eq 'renew') {
		# Nothing else supports renew -- return empty action
		debug "No safe command for renew $plan{type}";
		return ();
	} elsif ($plan{type} eq 'random') {
		@cmd = ('gen', $plan{size},);
		my ($path, $key) = split(':',$plan{path});
		push(@cmd, '--policy', $plan{valid_chars}) if $plan{valid_chars};
		push(@cmd, $root_path.$path, $key);
		if ($plan{format}) {
			my $dest = $plan{destination} || "$key-".$plan{format};
			push(@cmd, '--no-clobber') if $action eq 'add' || ($action eq 'recreate' && $plan{fixed});
			push(@cmd, '--', 'fmt', $plan{format}, $root_path.$path, $key, $dest);
		}
	} elsif ($plan{type} eq 'dhparams') {
		@cmd = ('dhparam', $plan{size}, $root_path.$plan{path});
	} elsif (grep {$_ eq $plan{type}} (qw/ssh rsa/)) {
		@cmd = ($plan{type}, $plan{size}, $root_path.$plan{path});
	} else {
		@cmd = (@cmd, 'prompt', 'bad request');
		debug "Requested to create safe path for an bad plan";
		dump_var plan => \%plan;
	}
	push(@cmd, '--no-clobber') if $action eq 'add' || ($plan{fixed} && $action eq 'recreate');
	push(@cmd, '--', 'prompt', "completed: $plan{type}|$plan{path}") if $batch; # for notification when batched.
	debug "safe command: ".join(" ", @cmd);
	dump_var plan => \%plan;
	return @cmd;
}

# }}}
# _process_x509_plans - determine signing changes, add defaults and specify build order {{{
sub _process_x509_plans {
	my ($plans, $paths, $root_ca_path, $validate) = @_;

	my @paths = @{$paths || []};
	my $base_cas = {};
	for (grep {$_ =~ /\/ca$/ || ($plans->{$_}{is_ca}||'') =~ 1} @paths) {
		$plans->{$_}{is_ca} = 1;
		push(@{$base_cas->{$plans->{$_}{base_path}} ||= []}, $_);
	}

	for my $base_path (CORE::keys %$base_cas) {
		next unless my $count = scalar(@{$base_cas->{$base_path}});
		my ($base_ca, $err);
		if ($count == 1) {
			# Use the ca for the base path
			$base_ca = $base_cas->{$base_path}[0];
		} elsif (grep {$_ eq "$base_path/ca"} @{$base_cas->{$base_path}}) {
			# Use the default ca if there's more than one
			$base_ca = "$base_path/ca";
		} else {
			# Ambiguous - flag this further down
			$err = "Unspecified/ambiguous signing CA";
		}

		my @signable_certs = grep {!$plans->{$_}{is_ca}
		                        &&  $plans->{$_}{base_path} eq $base_path
		                        && !$plans->{$_}{signed_by}
		                          } @paths;
		for (@signable_certs) {
			if ($err) {
				$plans->{$_}{type} = "error";
				$plans->{$_}{error} = "Ambiguous or missing signing CA"
			} else {
				$plans->{$_}{signed_by} = $base_ca;
			}
		}
	}

	my $signers = {};
	for (@paths) {
		my $signer = $plans->{$_}{signed_by} || '';
		push (@{$signers->{$signer} ||= []}, $_);
	}
	$signers->{$_} = [sort @{$signers->{$_}}] for (CORE::keys %$signers);
	_sign_unsigned_x509_plans($signers->{''}, $plans, $root_ca_path );

	my @ordered_plans;
	my $target = '';
	while (1) {
		_sign_x509_plans($target,$signers,$plans,\@ordered_plans,$validate);
		$target = _next_signer($signers);
		last unless $target;
	}

	# Find unresolved signage paths
	for (grep {$plans->{$_}{type} eq 'x509' && !$plans->{$_}{__processed}} sort(CORE::keys %$plans)) {
		$plans->{$_}{type} = "error";
		$plans->{$_}{error} = "Could not find associated signing CA";
		push(@ordered_plans, $plans->{$_})
	}

	return @ordered_plans;
}

# }}}
# _sign_unsigned_x509_plans - sign unsigned plans with the root CA if present, otherwise self-signed {{{
sub _sign_unsigned_x509_plans {
	my ($cert_paths, $plans, $root_ca) = @_;
	for my $path (@{$cert_paths||[]}) {
		next unless $plans->{$path}{type} eq 'x509' && !$plans->{$path}{signed_by};
		if ($root_ca) {
			$plans->{$path}{signed_by} = $root_ca;
			$plans->{$path}{signed_by_abs_path} = 1;
		} else {
			$plans->{$path}{self_signed} = 1;
		}
	}
}

# }}}
# _sign_x509_plans - process the certs in order of signer {{{
sub _sign_x509_plans {
	my ($signer,$certs_by_signer,$src_plans,$ordered_plans,$validate) = @_;
	if ($signer) {
		if (! grep {$_->{path} eq $signer} (@$ordered_plans)) {
			my ($idx) = grep {$certs_by_signer->{$signer}[$_] eq $signer} ( 0 .. scalar(@{$certs_by_signer->{$signer}})-1);
			if (defined($idx)) {
				# I'm signing myself - must be a CA
				unshift(@{$certs_by_signer->{$signer}}, splice(@{$certs_by_signer->{$signer}}, $idx, 1));
				$src_plans->{$signer}{self_signed} = 2; #explicitly self-signed
				$src_plans->{$signer}{signed_by} = "";
				$src_plans->{$signer}{is_ca} = 1;
			}
		}
	}
	while (my $cert = shift(@{$certs_by_signer->{$signer}})) {
		if (grep {$_->{path} eq $cert} (@$ordered_plans)) {
			# Cert has been added already - bail
			$src_plans->{$cert} ||= {};
			$src_plans->{$cert}{type}  = 'error';
			$src_plans->{$cert}{error} = 'Cyclical CA signage detected';
			return;
		}
		$src_plans->{$cert}{__processed} = 1;
		push(@$ordered_plans, $src_plans->{$cert})
			if ((!$validate) || _validate_x509_plan($src_plans,$cert,$ordered_plans));
		_sign_x509_plans($cert,$certs_by_signer,$src_plans,$ordered_plans,$validate)
			if scalar(@{$certs_by_signer->{$cert} || []});
	}
}

# }}}
# _next_signer - determine next signer so none are orphaned {{{
sub _next_signer {
	my $signers = shift;
	my @available_targets = grep {scalar(@{$signers->{$_}})} sort(CORE::keys %$signers);
	while (@available_targets) {
		my $candidate = shift @available_targets;
		# Dont use a signer if its signed by a remaining signer
		next if grep {$_ eq $candidate} map { @{$signers->{$_}} } @available_targets;
		return $candidate;
	}
	return undef;
}

# }}}
# _validate_x509_plan - check the cert plan is valid {{{
sub _validate_x509_plan {
	my ($plans,$cert_name, $ordered_plans) = @_;

	my %cert = %{$plans->{$cert_name}};
	my $err = "";
	$err .= "\n- Invalid valid_for argument: expecting <positive_number>[ymdh], got $cert{valid_for}"
		unless !$cert{valid_for} || ($cert{valid_for} || '') =~ /^[1-9][0-9]*[ymdh]$/;
	if ($cert{names}) {
		if (CORE::ref($cert{names}) eq 'HASH') {
			$err .= "\n- Invalid names argument: expecting an array of one or more strings, got a hashmap";
		} elsif (CORE::ref($cert{names}) eq '') {
			$err .= "\n- Invalid names argument: expecting an array of one or more strings, got the string '$cert{names}'"
		} elsif (CORE::ref($cert{names}) eq 'ARRAY') {
			if (! scalar @{$cert{names}}) {
				$err .= "\n- Invalid names argument: expecting an array of one or more strings, got an empty list";
			} elsif (grep {!$_} @{$cert{names}}) {
				$err .= "\n- Invalid names argument: cannot have an empty name entry";
			} elsif (grep {CORE::ref($_) ne ""} @{$cert{names}}) {
				$err .= "\n- Invalid names argument: cannot have an entry that is not a string";
			}
		}
	}
	if ($cert{usage}) {
		if (CORE::ref($cert{usage}) eq 'ARRAY') {
			my %valid_keys = map {$_, 1} _x509_key_usage();
			my @invalid_keys = grep {!$valid_keys{$_}} @{$cert{usage}};
			$err .= sprintf("\n- Invalid usage argument - unknown usage keys: '%s'\n  Valid keys are: '%s'",
											join("', '", sort @invalid_keys), join("', '", sort(CORE::keys %valid_keys)))
				if (@invalid_keys);
		} else {
			$err .= "\n- Invalid usage argument: expecting an array of one or more strings, got ".
			        (CORE::ref($cert{usage}) ? lc('a '.CORE::ref($cert{usage})) : "the string '$cert{usage}'");
		}
	}
	$err .= "\n- Invalid is_ca argument: expecting boolean value, got '$cert{is_ca}'"
		unless (!defined($cert{is_ca}) || $cert{is_ca} =~ /^1?$/);
	if ($cert{signed_by}) {
		$err .= "\n- Invalid signed_by argument: expecting relative vault path string, got '$cert{signed_by}'"
			unless ($cert{signed_by} =~ /^[a-z0-9_-]+(\/[a-z0-9_-]+)+$/);
		$err .= "\n- CA Common Name Conflict - can't share CN '".@{$cert{names}}[0]."' with signing CA"
			if (
				(CORE::ref($plans->{$cert{signed_by}})||'' eq "HASH") &&
				$plans->{$cert{signed_by}}{names} &&
				CORE::ref($cert{names}) eq 'ARRAY' &&
				CORE::ref($plans->{$cert{signed_by}}{names}) eq 'ARRAY' &&
				@{$cert{names}}[0] eq @{$plans->{$cert{signed_by}}{names}}[0]
			);
	}
	if ($err) {
		$plans->{$cert_name} = {%cert, type => 'error', error => "Bad X509 certificate request: $err"};
		push @$ordered_plans, $plans->{$cert_name};
		return undef;
	}
	return 1;
}

# }}}
# _validate_ssh_plan - check the ssh plan is valid {{{
sub _validate_ssh_plan {
	my ($plans,$path, $ordered_plans) = @_;
	my %plan = %{$plans->{$path}};
	my $err = "";
	$err .= "\n- Invalid size argument: expecting 1024-16384, got $plan{size}"
		if ($plan{size} !~ /^\d+$/ || $plan{size} < 1024 ||  $plan{size} > 16384);

	if ($err) {
		push @$ordered_plans, {%plan, type => 'error', error => "Bad SSH request: $err"};
		return undef;
	}
	return 1;
}

# }}}
# _validate_kit_secret - list keys expected for a given kit secret {{{
sub _validate_kit_secret {
	my ($scope,$plan,$secret_values,$root_path,$plans) = @_;

	# Existance
	my ($path,$key) = split(':', $root_path.$plan->{path});
	$path =~ s#^/?(.*?)/?$#$1#;
	$path =~ s#/{2,}#/#g;
	my $values = $secret_values->{$path};
	return ('missing') unless defined($values)
	                       && CORE::ref($values) eq 'HASH'
	                       && (!defined($key) || defined($values->{$key}));

	my @keys = _expected_kit_secret_keys(%$plan);
	return (
		'error',
		sprintf("Cannot process secret type '%s': unknown type",$plan->{type})
	) unless @keys;

	my $errors = join("\n", map {sprintf("%smissing key ':%s'", _checkbox(0), $_)} grep {! exists($values->{$_})} @keys);
	return ('missing',$errors) if $errors;
	return ('ok') unless $scope eq 'validate';

	my ($msg,%results);
	if ($plan->{type} eq 'x509') {
		my $key  = $values->{key};
		my $cert = $values->{certificate};
		my ($keyModulus) = run('openssl rsa -in <(echo "$1") -modulus  -noout', $key) =~ /Modulus=(\S*)/;
		my $certInfo = run('openssl x509 -in <(echo "$1") -text -fingerprint -modulus -noout', $cert);
		my ($issuerCN, $since, $expires, $subjectCN, $fingerprint, $modulus) =
			$certInfo =~ /Issuer: CN=(\S*).*Not Before: ([^\n]*).*Not After : ([^\n]*).*Subject: CN=([^\r\n]+?)\s*[\r\n]+.*Fingerprint=(\S*).*Modulus=(\S*)/ms;
		my $is_ca = $certInfo =~ /X509v3 Basic Constraints:.*(CA:TRUE).*Signature Algorithm/ms;

		# CN and SANs
		my (undef, $sanInfo) = $certInfo =~ /\n( *)X509v3 Subject Alternative Name:\s*?((?:[\n\r]+\1.*)+)/;
		my @SANs = ($sanInfo || '') =~ /(?:IP Address|DNS):([^,\n\r]+)/g;
		@SANs =  map {s/\s*$//; $_} @SANs;

		my $cn_str = ${$plan->{names}}[0];
		if ($cn_str) {
			$results{cn} = $subjectCN eq $cn_str;
			$cn_str = "'$cn_str'";
		} else {
			my $default_cn_re = qr/^ca\.n[0-9]{9}\.$plan->{base_path}/;
			$results{cn} = $subjectCN =~ $default_cn_re;
			$cn_str = $results{cn} ? "'$subjectCN'" : "matches default ca.n#########.$plan->{base_path}";
		}
		my (%sans,%desired_sans);
		@sans{grep {$_ ne $subjectCN} @SANs}=();
		@desired_sans{@{$plan->{names}}[1 .. scalar @{$plan->{names}}-1]}=();
		my @extra_sans = sort(grep {!exists $desired_sans{$_}} CORE::keys %sans);
		my @missing_sans = sort(grep {!exists $sans{$_}} CORE::keys %desired_sans);
		$results{sans} = !scalar(@extra_sans) && !scalar(@missing_sans);
		my $sans_str = " (".join('; ',(@missing_sans ? "missing: ".join(", ", @missing_sans):(), @extra_sans? "extra: ".join(", ", @extra_sans) : ())).")";
		$sans_str = ": ".join(", ", @SANs) if $sans_str eq " ()";

		# Signage and Modulus Agreement
		$results{is_ca} = !!$is_ca if $plan->{is_ca};
		my ($subjectKeyID) = $certInfo =~ /X509v3 Subject Key Identifier: *[\n\r]+\s+([A-F0-9:]+)\s*$/m;
		my ($authKeyID)    = $certInfo =~ /X509v3 Authority Key Identifier: *[\n\r]+\s+keyid:([A-F0-9:]+)\s*$/m;
		my $signed_by_str;
		my $self_signed = (!$plan->{signed_by} || $plan->{signed_by} eq $plan->{path});
		if ($self_signed) {
			$results{self_signed} = ($subjectKeyID && $authKeyID)
				? $subjectKeyID eq $authKeyID
				: $issuerCN eq $subjectCN;
		} else {
			my $signer_path = $plan->{signed_by_abs_path} ? $plan->{signed_by} : $root_path.$plan->{signed_by};
			$signer_path =~ s#^/##;
			my $ca_cert = $secret_values->{$signer_path}{certificate};
			if ($ca_cert) {
				my $caSubjectKeyID;
				if ($authKeyID) {
					# Try to use the subject and authority key identifiers if they exist
					my $caInfo = run('openssl x509 -in <(echo "$1") -text -noout', $ca_cert);
					($caSubjectKeyID) = $caInfo =~ /X509v3 Subject Key Identifier: *[\r\n]+\s+([A-F0-9:]+)\s*$/m;
				}
				if ($caSubjectKeyID) {
					$results{signed} = $authKeyID eq $caSubjectKeyID;
					$signed_by_str = '';
				} else {
					# Otherwise try to validate the full chain if we have access all the certs
					my $ca_plan;
					my $full_cert_chain='';
					while (1) {
						last unless $signer_path && defined($secret_values->{$signer_path});
						$full_cert_chain =  $secret_values->{$signer_path}{certificate}.$full_cert_chain;
						($ca_plan) = grep {$root_path.$_->{path} eq '/'.$signer_path} @$plans;
						last unless ($ca_plan && $ca_plan->{signed_by});

						($signer_path = $ca_plan->{signed_by_abs_path}
							? $ca_plan->{signed_by}
							: $root_path.$ca_plan->{signed_by}
						) =~ s#^/##
					}

					my $out = run(
						'openssl verify -verbose -CAfile <(echo "$1") <(echo "$2")',
						$full_cert_chain, $values->{certificate}
					);
					if ($out =~ /error \d+ at \d+ depth lookup/) {
						#fine, we'll check via safe itself - last resort because it takes time
						my $signer_path = $plan->{signed_by_abs_path} ? $plan->{signed_by} : $root_path.$plan->{signed_by};
						$signer_path =~ s#^/##;
						my ($safe_out,$rc) = Genesis::Vault::current->query('x509','validate','--signed-by', $signer_path, $root_path.$plan->{path});
						$results{signed} = $rc == 0 && $safe_out =~ qr/$plan->{path} checks out/;
					} else {
						$results{signed} = $out =~ /: OK$/;
					}
					$signed_by_str = $results{signed} ? '' :
						$subjectCN eq $issuerCN ? " (maybe self-signed?)" : "  (signed by CN '$issuerCN')"
				}
			} else {
				$results{signed} = 0;
				$signed_by_str = " (specified CA not found - ".
					($subjectCN eq $issuerCN ?
				               "maybe self-signed?)" : "found signed by CN '$issuerCN')");
			}
		}
		$results{modulus_agreement} = $modulus eq $keyModulus;

		my $now_t = Time::Piece->new();
		my $since_t   = Time::Piece->strptime($since,   "%b %d %H:%M:%S %Y %Z");
		my $expires_t = Time::Piece->strptime($expires, "%b %d %H:%M:%S %Y %Z");
		my $valid_str;
		if ($since_t < $now_t) {
			if ($now_t < $expires_t) {
				$valid_str = sprintf("expires in %.0f days (%s)",  ($expires_t - $now_t)->days(), $expires);
			} else {
				$valid_str = sprintf("expired %.0f days ago (%s)", ($now_t - $expires_t)->days(), $expires);
			}
		} else {
			$valid_str = "not yet valid (starts $since)";
		}
		$results{valid} = $valid_str =~ /^expires/;


		my ($usage, $usage_str);
		if (defined($plan->{usage})) {
			$usage = ($plan->{usage});
			$usage_str = "Specified key usage";
			if (!scalar @$usage) {
				$usage_str = "No key usage";
			}
		} elsif ($plan->{is_ca}) {
			$usage = [qw/server_auth client_auth crl_sign key_cert_sign/];
			$usage_str = "Default CA key usage";
		} else {
			$usage = [qw/server_auth client_auth/];
			$usage_str = "Default key usage";
		}

		my $usage_results = _x509_key_usage($certInfo,$usage);
		$results{usage} = !defined($usage_results->{extra}) && !defined($usage_results->{missing});
		my @extra_usage = @{$usage_results->{extra}||[]};
		my @missing_usage = @{$usage_results->{missing}||[]};
		my $usage_err_str = " (". join('; ',(
				@missing_usage ? "missing: ".join(", ", @missing_usage):(),
				@extra_usage   ? "extra: "  .join(", ", @extra_usage  ):()
		)).")";
		if ($usage_err_str eq " ()") {
			$usage_str .= ": ".join(", ", @$usage) if @$usage;
		} else {
			$usage_str .= $usage_err_str;
		}

		$msg .= sprintf("%s%sCA Certificate\n",    _checkbox($is_ca), $plan->{is_ca} ? '' : 'Not a ') if $is_ca || $plan->{is_ca};
		$msg .= $self_signed ?
						sprintf("%sSelf-Signed\n",         _checkbox($results{self_signed})) :
						sprintf("%sSigned by %s%s\n",      _checkbox($results{signed}), $plan->{signed_by}, $signed_by_str);
		$msg .= sprintf("%sValid: %s\n",           _checkbox($results{valid}), $valid_str);
		$msg .= sprintf("%sModulus Agreement\n",   _checkbox($results{modulus_agreement}));
		$msg .= sprintf("%sSubject Name %s%s\n",   _checkbox($results{cn}), $cn_str, $results{cn} ? '' : " (found '$subjectCN')");
		$msg .= sprintf("%sSubject Alt Names%s\n", _checkbox($results{sans}), $sans_str);
		$msg .= sprintf("%s%s\n", _checkbox($results{usage}), $usage_str);
	} elsif ($plan->{type} eq 'dhparam') {
		# TODO: figure out how to validate
	} elsif ($plan->{type} eq 'ssh') {
		my ($rendered_public,$priv_rc) = run('ssh-keygen -y -f /dev/stdin <<<"$1"', $values->{private});
		$results{priv} = !$priv_rc;
		$msg .= sprintf("%sValid private key\n",   _checkbox(!$priv_rc));
		my ($pub_sig,$pub_rc) = run('ssh-keygen -B -f /dev/stdin <<<"$1"', $values->{public});
		$results{priv} = !$pub_rc;
		$msg .= sprintf("%sValid public key\n",    _checkbox(!$pub_rc));
		if (!$priv_rc) {
			my ($rendered_sig,$rendered_rc) = run('ssh-keygen -B -f /dev/stdin <<<"$1"', $rendered_public);
			$results{agree} = $rendered_sig eq $pub_sig;
			$msg .= sprintf("%sPublic/Private key Agreement\n",      _checkbox($results{agree}));
		}
		if (!$pub_rc) {
			my ($bits) = $pub_sig =~ /^\s*([0-9]*)/;
			$results{size} = ($bits == $plan->{size});
			$msg .= sprintf("%s%s bits%s\n",        _checkbox($results{size}), $plan->{size}, $results{size} ? '' : " ( found $bits bits)" );
		}
	} elsif ($plan->{type} eq 'rsa') {
		my ($priv_modulus,$priv_rc) = run('openssl rsa -noout -modulus -in <(echo "$1")', $values->{private});
		$results{priv} = !$priv_rc;
		$msg .= sprintf("%sValid private key\n",   _checkbox(!$priv_rc));
		my ($pub_modulus,$pub_rc) = run('openssl rsa -noout -modulus -in <(echo "$1") -pubin', $values->{public});
		$results{priv} = !$pub_rc;
		$msg .= sprintf("%sValid public key\n",    _checkbox(!$pub_rc));
		if (!$pub_rc) {
			my ($pub_info, $pub_rc2) = run('openssl rsa -noout -text -inform PEM -in <(echo "$1") -pubin', $values->{public});
			my ($bits) = ($pub_rc2) ? () : $pub_info =~ /Key:\s*\(([0-9]*) bit\)/;
			$results{size} = (($bits || 0) == $plan->{size});
			$msg .= sprintf("%s%s bit%s\n",        _checkbox($results{size}), $plan->{size},
				$results{size} ? '' : ($bits ? " (found $bits bits)" : " (could not read size)"));
			if (!$priv_rc) {
				$results{agree} = $priv_modulus eq $pub_modulus;
				$msg .= sprintf("%sPublic/Private key agreement\n",      _checkbox($results{agree}));
			}
		}
	} elsif ($plan->{type} eq 'random') {
		$results{length} = $plan->{size} == length($values->{$key});
		my $length_str = $results{length} ? '' : " - got ". length($values->{$key});
		$msg .= sprintf("%s%s characters%s\n", _checkbox($results{length}), $plan->{size}, $length_str );
		if ($plan->{valid_chars}) {
			(my $valid_chars = $plan->{valid_chars}) =~ s/^\^/\\^/;
			$results{valid_chars} = $values->{$key} =~ /^[$valid_chars]*$/;
			$msg .= sprintf("%sOnly uses characters '%s'%s\n",
				_checkbox($results{valid_chars}), $valid_chars,
				$results{valid_chars} ? '' : " (found invalid characters in '$values->{$key}')");
		}
		if ($plan->{format}) {
			my ($secret_path,$secret_key) = split(":", $plan->{path},2);
			my $fmt_key = $plan->{destination} ? $plan->{destination} : $secret_key.'-'.$plan->{format};
			$results{formatted} = exists $values->{$fmt_key};
			$msg .= sprintf("%sFormatted as %s in ':%s'%s\n",
				_checkbox($results{formatted}), $plan->{format}, $fmt_key,
				$results{formatted} ? '' : " ( not found )");
		}

		# TODO: check other aspects... (valid_chars, fmt, etc)
	}
	return ((grep {!$results{$_}} CORE::keys %results) ? "error" : "ok", $msg);
}

# }}}
# _x509_key_usage - specify allowed usage values, and map openssl identifiers to tokens  {{{
sub _x509_key_usage {
	my ($openssl_text, $check) = @_;

	my %keyUsageLookup = (
		"Digital Signature" =>  "digital_signature",
		"Non Repudiation" =>    "non_repudiation",
		"Content Commitment" => "content_commitment", #Newer version of non_repudiation
		"Key Encipherment" =>   "key_encipherment",
		"Data Encipherment" =>  "data_encipherment",
		"Key Agreement" =>      "key_agreement",
		"Certificate Sign" =>   "key_cert_sign",
		"CRL Sign" =>           "crl_sign",
		"Encipher Only" =>      "encipher_only",
		"Decipher Only" =>      "decipher_only",
	);

	my %extendedKeyUsageLookup = (
		"TLS Web Client Authentication" => "client_auth",
		"TLS Web Server Authentication" => "server_auth",
		"Code Signing" =>                  "code_signing",
		"E-mail Protection" =>             "email_protection",
		"Time Stamping" =>                 "timestamping"
	);

	return uniq(values %keyUsageLookup, values %extendedKeyUsageLookup)
		unless defined($openssl_text);

	my %found = ();
	my ($specified_keys) = $openssl_text =~ /X509v3 Key Usage:.*[\n\r]+\s*([^\n\r]+)/;
	my ($specified_ext)  = $openssl_text =~ /X509v3 Extended Key Usage:.*[\n\r]\s*+([^\n\r]+)/;

	if ($specified_keys) {
		my @keys =  split(/,\s+/,$specified_keys);
		chomp @keys;
		$found{$_} = 1 for (grep {$_} map {$keyUsageLookup{$_}} @keys);
	}
	if ($specified_ext) {
		my @keys =  split(/,\s+/,$specified_ext);
		chomp @keys;
		$found{$_} = 1 for (grep {$_} map {$extendedKeyUsageLookup{$_}} @keys);
	}
	return CORE::keys(%found) unless (CORE::ref($check) eq "ARRAY");
	$found{$_}-- for uniq(@$check);
	if ( exists($found{non_repudiation}) && exists($found{content_commitment}) &&
	     (abs($found{non_repudiation} + $found{content_commitment}) < 1)) {
		# if both non_repudiation and content_commitment are found and/or requested,
		# then as long is the total sum is less than |1|, it is considered requested
		# and found (ie not both requested and none found or both found and none requested)
		$found{non_repudiation} = $found{content_commitment} = 0;
	}
	my @extra   = sort(grep {$found{$_} > 0} CORE::keys %found);
	my @missing = sort(grep {$found{$_} < 0} CORE::keys %found);

	return {
		extra =>   (@extra   ? \@extra   : undef),
		missing => (@missing ? \@missing : undef)
	}
}

#}}}
# _get_plan_paths - list all paths for the given plan {{{
sub _get_plan_paths {
	my $plan = shift;
	my @paths = $plan->{path};
	if ($plan->{type} eq 'random' && $plan->{format}) {
		my ($path,$key) = split(':',$plan->{path},2);
		push @paths, $path.":".($plan->{destination} ? $plan->{destination} : $key.'-'.$plan->{format})." (paired with $plan->{path})";
	}
	return @paths;
}

#}}}
## _checkbox - make a checkbox {{{
sub _checkbox {
	return bullet($_[0] ? 'good' : 'bad', '', box => 1, inline => 1, indent => 0);
}
# }}}
# }}}
1;

=head1 NAME

Genesis::Vault

=head1 DESCRIPTION

This module provides utilities for interacting with a Vault through safe.

=head1 Class Methods

=head2 new($url,$name,$verify)

Returns a blessed Genesis::Vault object based on the URL, target name and TLS verify values provided.

B<NOTE:> This should not be called directly, as it provides no error checking or validations.

=head2 target($target, %opts)

Returns a C<Genesis::Vault> object representing the vault at the given target
or presents the user with an interactive prompt to specify a target.  This is
intended to be used when setting up a deployment repo for the first time, or
selecting a new vault for an existing deployment repo.

In the case that the target is passed in, the target will be validated to
ensure that it is known, a url or alias and that its url is unique (not being
used by any other aliases); A C<Genesis::Vault> object for that target is
returned if it is valid, otherwise, an error will be raised.

In the case that the target is not passed in, all unique-url aliases will be
presented for selection, with the current system target being shown as a
default selection.  If there are aliases that share urls, a warning will be
presented to the user that some invalid targets are not shown due to that.
The user then enters the number corresponding to the desired target, and a
C<Genesis::Vault> object corresponding to that slection is returned.  This
requires that the caller is in a controlling terminal, otherwise the program
will terminate.

C<%opts> can be the following values:

=over

=item default_vault

A C<Genesis::Vault> that will be used as the default
vault selection in the interactive prompt.  If not provided, the current system
target vault will be used.  Has no effect when not in interactive mode.

=back

In either cases, the target will be validated that it is reachable, authorized
and ready to be used, and will set that vault as the C<current> vault for the
class.

=head2 attach($url, $insecure)

Returns a C<Genesis::Vault> object for the given url according to the user's
.saferc file.

This will result in an error if the url is not known in the .saferc or if it
is not unique to a single alias, as well as if the url is not a valid url.

The C<insecure> does not matter for the attach, but does change the error
output for describing how to add the target to the local safe configuration if
it is missing.

=head2 rebind

This is used to rebind to the previous vault when in a callback from a Genesis-
run hook.  It uses the C<GENESIS_TARGET_VAULT> environment variable that is set
prior to running a hook, and only ensures that the vault is known to the system.

=head2 find(%conditions)

Without any conditions, this will return all system-defined safe targets as
Genesis::Vault objects.  Specifying hash elemements of the property => value
filters the selection to those that have that property value (compared as string)
Valid properties are C<url>, C<name>, C<tls> and C<verify>.

=head2 find_by_target($alias_or_url)

This will return all Vaults that use the same url as the given alias or url.

=head2 default

This will return the Vault that is the set target of the system, or null if
there is no current system target.

=head2 current

This will return the Vault that was the last Vault targeted by Genesis::Vault
methods of target, attach or rebind, or by the explicit set_as_current method
on a Vault object.

=head2 clear_all

This method removes all cached Vault objects and the C<current> and C<default>
values.  Though mainly used for providing a clean slate for testing, it could
also be useful if the system's safe configuration changes and those changes need
to be picked up by Genesis during a run.

=head1 Instance Methods

Each C<Genesis::Vault> object is composed of the properties of url, its name
(alias) as it is known on the local system, and its verify (binary opposite of
skip-ssl-validation).  While these properties can be queried directly, it is
better to use the accessor methods by the same name

=head2 url

Returns the url for the Vault object, in the form of:
C<schema://host_name_or_ip:port>

The :port is optional, and is understood to be 80 for http schema or 443 for
https.

=head2 name

Returns the name (aka alias) of the vault as it is known on the local system.
Because the same Vault target url may be known by a different name on each
system, the use of the alias is not considered an precise identifier for a
Vault, and only used for convenience in display output or specifying a target
initially.

=head2 verify

Returns a boolean true if the vault target's certificate will be validated
when it is connected, or false if not.  Only applicable to https urls, though
http will default to true.

=head2 tls

Convenience method to check if using https (true) or http (false) rather than
having to substring or regex the url.

=head2 query

Allows caller to pass a generic query to the selected vault.  The user can
specify anything that would normally come after `safe ...` on the command line,
but not the -T <target> option will NOT have any effect.

This can take the same arguments and returns the same structure that a
C<Genesis::run> method would, with two caveats:

=over

=item *

Setting the environment variable SAFE_TARGET will get overwritten with the url
of the Vault object being operated on.

=item *

Setting the DEBUG environment variable will get unset because it is disruptive
to the call.  If you want to see the call being made so you can debug it, run
the Genesis command with -T or set the GENESIS_TRACE variable to 1

=back

=head2 get($path[, $key])

Return the string of the given path and key, or return the entire content under
the given path if no key is given.  The path does not have to be an end node
that contains keys; it can be a branch path, in which case all the sub-paths
and their key:value pairs will be returned.

=head2 set($path, $key[, $value])

If a value is specified, it will set that value (as a string) to the given key
on the specified path.  If no value is provided, an interactive mode will be
started where the user will be prompted to enter the value.  This will be
'dotted' out on the screen, and the user will have to enter the same value
again to confirm the correctness of their entry.

=head2 has($path[, $key])

Returns true if the vault contains the path and optionally the key if given.
Equivalent to C<safe exists $path> or C<safe exists $path:$key> as appropriate.

=head2 paths([@prefixes])

Returns a list of all paths in the vault if no prefix was specified, or all
paths that can be found under the specified prefixes.  If you ask for
overlapping prefixes, paths that match multiple prefixes will be returned
multiple times.

Note that this will only return node paths (paths that contain keys on their
last path segment, so if a vault only contains
B<secret/this/is/my/long/path:key> and you asked for paths, it would only
return that entry, not each partial path.

=head2 keys

Similar to C<paths> above, but also includes the B<:key> suffix for each key
under the matching paths.

=head2 status

Returns the status of the vault.  This is a string value that can be one of the
following:

=over

=item unreachable

This means that the vault url or port is not responding to connection attempts.
This may be because the C<vault> executable has stopped working, or due to
networking issue (e.g.: VPN not connected)

=item unauthenticated

This means that the vault is responding, but the local safe token has expired
or not been set.  Run C<safe auth ...> to connect, then try the command again.

=item sealed

The vault is sealed, and must be unsealed by the administrator before you can
access it.

=item uninitialized

The vault is responding and authenticated, but does not look like it was
correctly initialized with safe.

This may be a basic vault that was stood up manually -- to resolve this, simply
run `safe set secret/handshake knock=knock` once you're sure your talking to
the correct vault.  If you are using a different secret mount in your
environments, replace '/secret/' with the same mount that your environments
use.

=item ok

The vault is operating normally and the user is authenticated.

=back

=head2 env

This returns a hash of the environment variable names and values for
configuring the vault for things that use the basic Hashicorp vault environment
variables to target a vault, such as C<spruce>.  This can be fed directly into
the C<Genesis::run> commands C<env> option.

=head2 token

The authentication token for the vault, as stored in the C<.saferc> file.

=head2 set_as_current

Set the vault object as the current vault object used by this run of Genesis.
This is sometimes needed when dealing with legacy aspects of genesis
(pipelines, params from kit.yml) where there is no passing in of the C<Env> or
C<Top> object.

This is automatically called by C<target>, C<attach> and C<rebind> and
generally doesn't need to be manually set, but there are a few circumstances
that it may be necessary, so this was exposed as a public method.

=cut

# vim: fdm=marker:foldlevel=1:noet
