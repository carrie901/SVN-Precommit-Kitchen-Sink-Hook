#! /usr/bin/env perl
########################################################################

use strict;
use warnings;

use Data::Dumper;
use Getopt::Long;
use Pod::Usage;

use constant {
    SVNLOOK_DEFAULT	=> '/usr/bin/svnlook',
    SVN_REPO_DEFAULT	=> '/path/to/repository',
    SECTION_HEADER	=> qr/^\s*\[\s*(\w+)\s+(.*)\]\s*$/,
    PARAMETER_LINE	=> qr/^\s*(\w+)\s*=\s*(.*)$/,
    SVNLOOK_CHANGED	=> 'changed',
    SVNLOOK_PROPLIST	=> 'proplist',
    SVNLOOK_PROPGET	=> 'propget',

    #
    # FILE CHANGE STATUSES
    #
    ADDED		=> 'A',
    DELETED		=> 'D',
    MODIFIED		=> 'M',
};

use constant { 		#Control File Type (package Control)
    FILE_IN_REPO	=> "R",
    FILE_ON_SERVER	=> "F",
};

use constant {		#Revision file Type (package Configuration)
    TRANSACTION 	=> "T",
    REVISION		=> "R",
};

########################################################################
# GET PARAMETERS
#
my %parameters;
$parameters{svnlook}		= SVNLOOK_DEFAULT;
$parameters{file}		= SVN_REPO_DEFAULT;

GetOptions (
    \%parameters,
    'svnlook=s',		#Location of 'svnlook' command
    'file=s',			#Location of control file on server
    'filelocations=s@',		#Location of control files in repository
    't=s',			#Repository Transaction 
    'r=i',			#Repository Revision Number
    'parse',			#Only parse control file for errors
    'help',			#Display command line help
    'documentation',		#Display the entire Documentation
) or pod2usage ( -message => "Invalid parameters passed" );
$parameters{svn_repo} = shift;
my $configuration = Configuration->new;
my @configuration_errors = check_options( $configuration, \%parameters );

if ( @configuration_errors ) {
    print "ERRORS: Bad configuraiton:\n";
    for my $error ( @configuration_errors ) {
	print "* $error\n";
    }
    exit 2;
}
#
#
########################################################################

########################################################################
# MAIN PROGRAM
#

#
# Put all the control files into @control_file_list
#
my @control_file_list;
if ( defined $parameters{file} ) {
    push @control_file_list, Control_file->new( FILE_ON_SERVER, $parameters{file} );
}

for my $control_file ( @{ $parameters{filelocations} } ) {
    push @control_file_list,
	Control_file->new(FILE_IN_REPO, $control_file, $configuration);
}

#
# Parse the control files, and put the information in $sections
#

my $sections = Section_group->new;
my @parse_errors =  parse_control_files( $sections, \@control_file_list );
my @missing_params = verify_parameters( $sections );

#
# If there were any errors in the control files, display them and exit
#
my @errors = ( @parse_errors, @missing_params );
if ( @errors ) {
    for my $error ( @errors ) {
	warn $error->Get_error . "\n";
	warn "-" x 72 . "\n";
    }
    exit 2;
}

#
# Exit if all the user wanted to do was parse the control files
#

if ( exists $parameters{parse} ) {
    print qq(Control files are valid\n);
    print "Resulting structure:\n";
    $Data::Dumper::Indent = 1;
    print Dumper ( $sections ) . "\n";
    exit 0;
}

#
# Find all the groups that the author is in
#

my @authors_groups = find_groups ( $sections );

#
# Purge the file rules, so only rules mentioning users are included
#

my $files_rules_ref = $sections->File;
my @purged_file_rules = purge_file_rules (
    $files_rules_ref,
    $configuration->Author,
    \@authors_groups,
);

#
# Go through all files in the commit and look for file permissions,
# bans, and required properties.
#

my $command = join ( " ",
    $configuration->Svnlook,
    SVNLOOK_CHANGED,
    $configuration->Rev_param,
    $configuration->Repository,
);

open my $cmd_fh, "-|", $command 
    or die qq(Cannot fetch changes "$command");

#
# You also want to parse any control file that was committed to
# make sure it's valid.
#

my %control_files_index;
map { $control_files_index{$_} = 1 } @{ $parameters{filelocations} };
my @violations;
while ( my $line = <$cmd_fh> ) {
    chomp $line;
    $line =~ /\s*(\w)\s+(.*)/;
    my $change_type = $1;
    my $file = "/$2";	#Prepend "/" for root
    my $file_rules_ref = $sections->File;
    push @violations, check_file( $file_rules_ref, $file, $change_type );
    if ( $change_type eq ADDED ) {
	my $ban_rules_ref = $sections->Ban;
	push @violations, check_bans( $ban_rules_ref, $file );
    }
    if ( not $change_type eq DELETED ) {
	my $properties_rules_ref = $sections->Property;
	push @violations, check_properties (
	    $properties_rules_ref,
	    $file,
	    $configuration);
    }
    if ( $control_files_index{$file} ) {  #This is a control file. Parse
	push @violations, check_control_file_for_errors($file, $configuration);
    }
}

#
# Now check for Revision Properties
#

push @violations, check_revision_properties( $sections->Revprop );

#
# If there are violations, report them
#

if ( @violations ) {
    for my $violation ( @violations ) {
	my $file = $violation->File;
	my $error = $violation->Error;
	my $policy = $violation->Policy;
	print STDERR qq(COMMIT VIOLATION: In "$file"\n);
	print STDERR qq(    $policy\n);
	print STDERR qq(    $error\n);
	print "-" x 72 . "\n";
    }
    exit 2;
}
else { #There are no violations. Allow commit
    exit 0;
}
#
# END
########################################################################

########################################################################
# SUBROUTINE check_options
#
# Description: Verifies options that were passed into program
#
# Parameters:
#     $configuration:	An object of the $configuration class
#     %parameters:	The parameters in a hash
#
# Returns;
#     @config_errors:	A list of strings describing all configuration
#     			errors. If empty, there are no errors.
#
sub check_options {
    my $configuration	= shift;	#Configuration Object
    my %parameters 	= %{ shift() };

    #
    # Does the user want help?
    #
    if ( exists $parameters{documentation} ) {
	pod2usage ( -exitstatus => 0, -verbose => 2 );
    }

    if ( exists $parameters{help} ) {
	pod2usage ( -verbose => 0, -exitstatus => 0 );
    }

    #
    # Check and set the configurations
    #
    my @config_errors;

    # Location of svnlook command
    eval { $configuration->Svnlook($parameters{svnlook}); };
    if ( $@ ) {
	my $error = qq(Location "$parameters{svnlook}" )
	    . qq(is not a valid "svnlook" command);
	push @config_errors, $error;
    }

    if ( not ( exists $parameters{file}
		or exists $parameters{filelocations} ) ) {
	push @config_errors, "Need to specify a control file";
    }
    
    # Repository Location
    if ( not defined $parameters{svn_repo} ) {
	push @config_errors, "Need to pass the repository name";
    }
    $configuration->Repository($parameters{svn_repo});

    # Transaction or Revision Number
    if ( not ( exists $parameters{r} or exists $parameters{t} ) ) {
	push @config_errors, "Must specify a repo transaction or revision";
    }

    if ( exists $parameters{r} and exists $parameters{t} ) {
	push @config_errors, qq(Cannot specify both "-t" and "-r" parameters");
    }

    if ( exists $parameters{r} ) {
	$configuration->Rev_param( "-r $parameters{r}" );
    }
    else {
	$configuration->Rev_param( "-t $parameters{t}" );
    }

    eval { $configuration->Set_author if not $parameters{parse}; };
    if ( $@ ) {
	push @config_errors, qq(Cannot set author: $@);
    }
    return wantarray ? @config_errors : \@config_errors;
}
#
########################################################################

########################################################################
# SUBROUTINE parse_control_files
#
# Description: Parses the various control files in the configuration
#              and puts them into a handy-dandy convient structre for
#              future processing.
#
# Parameters:
#     $sections:		An object of Section_group type. This
#     				structure will be modified with the contents
#     				of all the various control files.
#     $control_file_list_ref	A list of all the Control_file class objects,
#     				each representing a control file that is to
#     				be parsed.
# Returns:
#     @parse_errors:		A list of all the errors found when parsing
#				the various control files. These are objects
#				of the Parse_error class.
# 
sub parse_control_files {
    my $sections		= shift;
    my $control_file_list_ref	= shift;

    my @parse_errors;		#All errors found

    for my $control_file ( @{ $control_file_list_ref } ) {
	my $section;		#Section object: defined when section header is read
	my $section_error;	#Does the section header have an error?
	my $line_number = 0;	#Track line numbers in control files for errors
	for my $line ( $control_file->Content ) {
	    $line_number++;
	    next unless $line;	#Ignore blank lines
	    if ( $line =~ SECTION_HEADER ) {
		my $section_type = $1;
		my $description  = $2;
		eval { $section = Section->new( $section_type, $description ); };
		if ( $@ ) {
		    $section_error = 1;	#Bad Section header, skip to next section
		    my $error = qq(Invalid Section Type "$section_type");
		    push @parse_errors,
			Parse_error->new($error, $control_file, $line_number);
		}
		else {
		    $section_error = 0;	#Section Header is good
		    $sections->Add($section);
		    $section->Control_file_line($line_number);
		    $section->Control_file($control_file);
		}
	    }
	    elsif ( $line =~ PARAMETER_LINE ) {
		my $parameter	= $1;
		my $value	= $2;
		if ( not $section_error ) {
		    eval { $section->Parameter( $parameter, $value ); };
		    if ($@) {
			my $error = qq(Invalid Parameter "$parameter");
			push @parse_errors,
			    Parse_error->new($error, $control_file, $line_number);
		    }
		}
	    }
	    else { #Invalid Line
		my $error = qq(Invalid Line in "$line");
		push @parse_errors,
	    	    Parse_error->new($error, $control_file, $line_number);
	    }
	}
    }
    return wantarray ? @parse_errors : \@parse_errors
}


#
########################################################################

########################################################################
# SUBROUTINE verify_parameters
#
sub verify_parameters {
    my $sections	= shift;

    my @missing_params;
    for my $method ( $sections->Sections ) {
	for my $section ( $sections->$method ) {
	    eval { $section->Verify_parameters; };
	    if ($@) {
		my $control_file = $section->Control_file;
		my $line_number = $section->Control_file_line;
		( my $error = $@ ) =~ s/ at .*$//;
		push @parse_errors,
		    Parse_error->new( $error, $control_file, $line_number);
	    }
	}
    }
    return @missing_params;
}
#
########################################################################

########################################################################
# SUBROUTINE find_groups
#
# Description: This subroutine locates all of the groups that the
#              Author is a member of. It used Ldap and Section group
#              definitions. If a group definition contains a group, and
#              one of the members of that group is a group the author is
#              in, the author will be a member of the parent group.
#
# Parameters:
#    $section:		A Section_group object representing all of the
#    			various control file configurations. The
#    			$section->Group and $section->Ldap groups will both
#    			be parsed.
#
# Returns:
#   @author_groups:	A list of groups that the Author of the change
#   			belongs to.
#
sub find_groups {
    my $section		= shift;

    if ( ref $section ne "Section_group" ) {
	die qq(Must pass object of Section_group class);
    }

    my @authors_groups = qw(all);	#Everyone is a member of "ALL"
    my %authors_group_index;
    #
    # LDAP Groups User Is In
    #
    for my $ldap ( $sections->Ldap ) {
	push @authors_groups, $ldap->Ldap_groups($configuration->Ldap_user);
    }
    map { $authors_group_index{$_} = 1 } @authors_groups;
    #
    # Get Group List Defined in Control File
    #

    GROUP:
    for my $group ( $sections->Group ) {
	my $group_name = lc $group->Description;
	for my $user ( $group->Users ) {
	    if ( $user eq $configuration->Author ) { #Author is in this group
		push @authors_groups, $group_name;
		$authors_group_index{$group_name} = 1;
		next GROUP;
	    }
	    if ( $user =~ s/^\@(.+)/$1/ ) { #This is a group and not a user
		#
		# See if Author is a member of this group
		#
		my $group = $1;
		if ( $authors_group_index{$group} ) {
		    push @authors_groups, $group_name;
		    $authors_group_index{$group_name} = 1;
		    next GROUP;
		}
	    }
	}
    }
    return wantarray ? @authors_groups : \@authors_groups;
}
#
########################################################################

########################################################################
# SUBROUTINE purge_file_rules
#
# Description:	This purges all unnecessary rules from a list of
# 		Section::File types. Unnecessary rules are rules
# 		that don't involve the author (i.e., the author nor
# 		one of the groups the author is in is in File->Users).
# Parameter:
#    @file_rules:	A list of Section::File object types.
#    $author:		The author.
#    @author_groups:	A list of all groups the author is already a member
#    			of.
# Returns:
#    @purged_rules: 	A list of the purged rules.
#
sub purge_file_rules {
    my $file_rules_ref	= shift;
    my $author		= shift;
    my $groups_ref	= shift;

    my @authors_groups = @{ $groups_ref };
    my %authors_groups_index;
    map { $authors_groups_index{$_} = 1 } @authors_groups;

    my @purged_file_rules;
    for my $file_rule ( @{ $file_rules_ref } ) {
	for my $user ( $file_rule->Users ) {
	    if ( $user =~ /^\@(.*)/ ) { 	#This is a group
		my $group = $1;
		if ( $authors_groups_index{$group} ) {
		    push @purged_file_rules, $file_rule;
		}
	    }
	    else {				#This is a user. Is this the author?
		if ( $author eq $user ) {
		    push @purged_file_rules, $file_rule;
		}
	    }
	} 	#for my $user ( $file_rule->Users ) {
    }	#for my $file_rule ( @{ $file_rules_ref } ) {
    return @purged_file_rules;
}
#
########################################################################

sub check_file { 
    my $file_rules_ref	= shift;
    my $file_name	= shift;
    my $change_type	= shift;

    my %change_desc = (
	A => "add",
	D => "delete",
	M => "modify",
    );

    my @violations;
    my $description;		#Need last description
    my $permitted = 1;		#Assume user has permission to do this
    for my $file_rule ( @{ $file_rules_ref } ) {
	my $regex = $file_rule->Match;
	my $access = $file_rule->Access;
	my $case = $file_rule->Case;
	$description = $file_rule->Description;

	if ( $case eq "ignore" ? $file_name =~ /$regex/i : $file_name =~ /$regex/ ) {
	    if    ( $access eq "read-write" ) {
		$permitted = 1;
	    }
	    elsif ( $access eq "read-only" ) {
		$permitted = 0;
	    }
	    elsif ( $access eq "add-only" ) {
		$permitted =  $change_type eq ADDED ? 1 : 0;
	    }
	    elsif ( $access eq "no-add" ) {
		$permitted = $change_type ne ADDED ? 1 : 0;
	    }
	    elsif ( $access eq "no-delete" ) {
		$permitted = $change_type ne DELETED ? 1 : 0;
	    }
	}
    }
    if ( not $permitted ) {
	my $violation = Violation->new( $file_name, $description );
	$violation->Policy( "You don't have access to $change_desc{$change_type} file_name." );
	return $violation;
    }
    else {
	return;
    }
}

sub check_bans {
    my $ban_rules_ref	= shift;
    my $file_name	= shift;

    for my $ban_rule ( @{ $ban_rules_ref } ) {
	my $regex = $ban_rule->Match;
	my $case = $ban_rule->Case;
	if ( $case eq "ignore" ? $file_name =~ /$regex/i : $file_name =~ /$regex/ ) {
	    my $violation = Violation->new( $file_name, $ban_rule->Desciption );
	    $violation->Policy("File name is not permitted to be added into repository");
	    return $violation;
	}
    }
    return;	#Not banned
}

sub check_properties {
    my $prop_rules_ref	= shift;
    my $file		= shift;
    my $configuration	= shift;

    my @violations;
    my %properties;	# Properties on the file

    #
    # Fetch all current properties and their values for this file
    #
    my $command = join ( " ",	#Find what properties the file has
	$configuration->Svnlook,
	SVNLOOK_PROPLIST,
	$configuration->Rev_param,
	$configuration->Repository,
	$file,
    );

    while ( my $property = qx($command) ) { #Fetch the property for that file
	chomp $property;
	my $command = join ( " ",
	    $configuration->Svnlook,
	    SVNLOOK_PROPGET,
	    $configuration->Rev_param,
	    $configuration->Repository,
	    $property,
	);
	chomp ( $properties{$property} = qx($command) );
    }

    #
    # We now have a list of properties and their values. Let's see which ones we need
    #
    PROP_RULE:
    for my $prop_rule ( @{ $prop_rules_ref } ) {
	my $regex = $prop_rule->Match;
	if ( ( $prop_rule->Case eq "ignore" and $file !~ /$regex/i )
		or $prop_rule->Case eq "ignore" and $file !~ /$regex/ ) {
	    next PROP_RULE;	# This rule doesn't apply to the file
	}
	
	#
	# Matching Prop_rule found: See if the file has that property
	#
	my $property = $prop_rule->Property;
	if ( not exists $properties{$property} ) { #Missing property
	    my $violation = Violation->new( $file, $prop_rule->Description );
	    $violation->Policy( qq(Missing property "$property" on "$file") );
	    push @violations, $violation;
	    next PROP_RULE;
	}

	#
	# File has that property: See if the value matches what it should be
	#
	else {    #Property exists: See if it matches
	    my $prop_value = $prop_rule->Value;
	    if    ( $prop_rule->Type eq "string"
		    and $properties{$property} ne $prop_value ) {
		my $violation = Violation->new( $file, $prop_rule->Description );
		$violation->Politcy( qq(Property "$property" did not match value "$prop_value") );
		push @violations, $violation;
		next PROP_RULE;

	    }
	    elsif ( $prop_rule->Type eq "number"
		    and $properties{$property} != $prop_value ) {
		my $violation = Violation->new( $file, $prop_rule->Description );
		$violation->Politcy( qq(Property "$property" did not equal "$prop_value") );
		push @violations, $violation;
		next PROP_RULE;
	    }
	    elsif ( $prop_rule->Type eq "regex" 
		    and $properties{$property} !~ /$regex/ ) {
		my $violation = Violation->new( $file, $prop_rule->Description );
		$violation->Politcy( qq(Property "$property" did not match regex "$prop_value") );
		push @violations, $violation;
		next PROP_RULE;
	    }
	    else {	# Invalid type: Cannot check rule
		my $violation = Violation->new( $file, $prop_rule->Description );
		$violation->Policy( qq(Bad property type on "$property" in control file) );
		push @violations, $violation;
		next PROP_RULE;
	    }
	}	#NEXT PROP_RULE

    } 
    return @violations;
}

sub check_control_file {
    my $file		= shift;
    my $configuration	= shift;

    my @control_file = ( Control_file->new(FILE_IN_REPO, $file, $configuration) );
    my $sections = Section_group->new;
    my @parse_errors =  parse_control_files( $sections, \@control_file_list );

    my $error_message;
    if ( @parse_errors ) {
	for my $error ( @parse_errors ) {
	    $error_message .= $error->Get_error . "\n";
	    $error_message .= "-" x 72 . "\n";
	}
	my $violation = Violation->new( $file, "$error_message" );
	$violation->Policy("Invalid Control File");
	my @violations = ( $violation );
	return wantarray ? @violations : \@violations;

    }
    else {
	return;
    }
}


########################################################################
# PACKAGE Configuration
#
# Description
# Stores the configuration information for the transaction. This
# includes the initial parameters, the control files, the sections,
# the user, etc.
#    
package Configuration;
use Carp;

sub new {
    my $class		= shift;

    my $self = {};
    bless $self, $class;
    return $self;
}

sub Author {
    my $self		= shift;
    my $author		= shift;

    if ( defined $author ) {
	$self->Ldap_user($author);	#Preserved with spaces and case;
	$author =~ s/\s+/_/g;		#Replace whitespace with underscores
	$self->{AUTHOR} = lc $author;
    }
    return $self->{AUTHOR};
}

sub Ldap_user {
    my $self		= shift;
    my $ldap_user	= shift;

    if ( defined $ldap_user ) {
	$self->{LDAP_USER} = $ldap_user;
    }
    return $self->{LDAP_USER};
}

sub Set_author {
    my $self		= shift;

    if ( not $self->Svnlook ) {
	croak qq(Need to set where "svnlook" command is located first);
    }

    if ( not $self->Rev_param ) {
	croak qq(Need to set the revision or transaction parameter first);
    }
    if ( not $self->Repository ) {
	croak qq(Need to set the repository location first);
    }

    my $svnlook = $self->Svnlook;
    my $rev	= $self->Rev_param;
    my $repo	= $self->Repository;
    my $author;
    my $command = qq("$svnlook" author $rev "$repo");
    eval { $author = qx($command) };
    if ( $@ ) {
	croak qq(Failed to execute command "$command");
    }
    chomp $author;
    if ( not $author ) {
	croak qq(Cannot locate author of revision "$rev" in repo "$repo");
    }
    return $self->Author($author);
}

sub Repository {
    my $self		= shift;
    my $repository	= shift;

    if ( defined $repository ) {
	$repository =~ s{\\}{/}g;	#Change from Windows to Unix file separators
	$self->{REPOSITORY} = $repository;
    }

    return $self->{REPOSITORY};
}

sub Rev_param {
    my $self		= shift;
    my $rev_param	= shift;

    if ( defined $rev_param and  $rev_param =~ /^-[tr]/ )  {
	$self->{REV_PARAM} = $rev_param;
    }
    elsif ( defined $rev_param and $rev_param !~ /^[tr]/ ) {
	croak qq(Revision parameter must start with "-t" or "-r");
    }
    return $self->{REV_PARAM};
}

sub Svnlook {
    my $self		= shift;
    my $svnlook		= shift;

    if ( defined $svnlook ) {
	if ( not -x $svnlook ) {
	    croak qq(The program "$svnlook" is not an executable program");
	}
	$self->{SVNLOOK} = $svnlook;
    }

    return $self->{SVNLOOK};
}
#
# END: Class:Configuration
########################################################################

########################################################################
# PACKAGE Control_file
#
# Stores Location, Type, and Contents of the Control File
#
package Control_file;
use Data::Dumper;
use Carp;

use constant {
    FILE_IN_REPO	=> "R",
    FILE_ON_SERVER	=> "F",
};

sub new {
    my $class		= shift;
    my $type		= shift;
    my $location	= shift;
    my $configuration	= shift;	#Needed if file is in repository

    if ( not defined $type ) {
	croak qq/Must pass in control file type ("R" = in repository. "F" = File on Server")/;
    }
    if ( not defined $location ) {
	croak qq(Must pass in Control File's location);
    }

    if ( $type eq FILE_IN_REPO and not defined $configuration ) {
	croak qq(Need to pass a configuration when control file is in the repository);
	if ( not $configuration->isa( "Configuration" ) ) {
	    croak qq(Configuration parameter needs to be of a Class "Configuration");
	}
    }

    my $self = {};
    bless $self, $class;
    $self->Type($type);
    $self->Location($location);

    #
    # Get the contents of the file
    #

    if ( $type eq FILE_ON_SERVER ) {
	my $control_file_fh;
	open $control_file_fh, "<", $location or
	    croak qq(Invalid Control file "$location" on server.);
	my @file_contents = <$control_file_fh>;
	close $control_file_fh;
	chomp @file_contents;
	$self->Content(\@file_contents);
    }
    else {
	my $rev_param   = $configuration->Rev_param;
	my $svnlook     = $configuration->Svnlook;
	my $repository  = $configuration->Repository;
	my @file_contents;
	eval {
	    @file_contents = qx($svnlook cat $rev_param $repository $location);
	};
	if ($@) {
	    croak qq(Couldn't retreive contents of control file)
	    . qq("$location" from repository "$repository");
	}
	$self->Content(\@file_contents);
    }
    return $self;
}

sub Location {
    my $self		= shift;
    my $location	= shift;

    if ( defined $location ) {
	$self->{LOCATION} = $location;
    }
    return $self->{LOCATION};
}

sub Type {
    my $self		= shift;
    my $type		= shift;

    if ( defined $type ) {
	if ( $type ne FILE_IN_REPO and $type ne FILE_ON_SERVER ) {
	    croak qq(Type must be either ") . FILE_IN_REPO
	    . qq(" or ") . FILE_ON_SERVER . qq(".);
	}
	$self->{TYPE} = $type;
    }
    return $self->{TYPE};
}

sub Content {
    my $self		= shift;
    my $contents_ref	= shift;

    $self->{CONTENTS} = [] if not exists $self->{CONTENTS};
    if ( defined $contents_ref ) {
	my @contents;
	for my $line ( @{$contents_ref} ) {
	    $line =~ s/^\s*$//;		#Make blank lines empty
	    $line =~ s/^\s*[#;].*//;	#Make comment lines empty
	    push @contents, $line;
	}
	$self->{CONTENTS} = \@contents;
    }
    my @contents = @{ $self->{CONTENTS} };
    return wantarray ? @contents : \@contents;
}
#
########################################################################

########################################################################
# PACKAGE Section
#
# Various Section Objects. Each one is a different type and has
# have different attributes. Master is for general definition
#

package Section;
use Data::Dumper;
use Carp;

use constant {
    FILE_IN_REPO	=> "R",
    FILE_ON_SERVER	=> "F",
};

sub new {
    my $class		= shift;
    my $type		= shift;
    my $description	= shift;

    if ( not defined $type or not defined $description ) {
	croak qq(You must pass in the Section type and Description);
    }

    $type = ucfirst lc $type;	#In the form of a Sub-Class Name

    $class .= "::$type";

    my $self = {};
    bless $self, $class;

    if ( not $self->isa("Section") ) {
	croak qq(Invalid Section type "$type" in control file);
    }

    $self->Description($description);
    return $self;
}

sub Description {
    my $self		= shift;
    my $description	= shift;

    if ( defined $description ) {
	$self->{DESCRIPTION} = $description;
    }
    return $self->{DESCRIPTION};
}

sub Control_file {
    my $self		= shift;
    my $control_file 	= shift;

    if ( defined $control_file ) {
	if ( ref $control_file ne "Control_file" ) {
	    croak qq(Control file must be of a type "Control_file");
	}
	$self->{CONTROL_FILE_NAME} = $control_file;
    }
    return $self->{CONTROL_FILE_NAME};
}

sub Control_file_line {
    my $self		= shift;
    my $line_number	= shift;

    if ( defined $line_number ) {
	$self->{LINE_NUMBER} = $line_number;
    }
    return $self->{LINE_NUMBER};
}

sub Parameter {
    my $self		= shift;
    my $parameter	= shift;
    my $value		= shift;

    if ( not defined $parameter ) {
	croak qq(Missing parameter "parameter");
    }
    my $method = ucfirst lc $parameter;

    if ( not $self->can($method) ) {
	croak qq(Invalid parameter "$parameter" passed);
    }

    if ( defined $value ) {
	return $self->$method($value);
    }
    else {
	return $self->$method;
    }
}

sub Verify_parameters {
    my $self		= shift;
    my $req_method_ref	= shift;

    my @req_methods = @{ $req_method_ref };

    #
    # Call the various methods
    #
    for my $method ( @req_methods ) {
	$method = ucfirst lc $method;
	eval { $self->$method; };
	if ( $@ or not $self->$method ) {
	    croak qq(Missing required parameter "$method");
	}
    }
    return 1;
}

sub glob2regex {
    my $glob = shift;

    # Due to collision when replacing "*" and "**", we use the NUL
    # character as a temporary replacement for "**" and then replace
    # "*". After this is done, we can replace NUL with ".*".

    $glob =~ s{\\}{/}g; 		#Change backslashes to forward slashes

    # Quote all regex characters
    ( my $regex = $glob ) =~ s{([\.\+\{\}\[\]])}{\\$1}g;

    # Replace double asterisks. Use \0 to mark place
    $regex =~ s{\*\*}{\0}g;

    # Replace single asterisks only
    $regex =~ s/\*/[^\/]*/g;

    # Replace ? with .
    $regex =~ s/\?/./g;

    # Replace \0 with ".*"
    $regex =~ s/\0/.*/g;

    return "^$regex\$";
}
#
# END: CLASS: Section
########################################################################

########################################################################
# CLASS: Section::Group
#
package Section::Group;
use Data::Dumper;
use base qw(Section);
use Carp;

use constant REQ_PARAMETERS	=> qw(Users);

sub Users {
    my $self		= shift;
    my $users		= shift;

    if ( defined $users ) {
	$self->{USERS} = [];	#Redefines all users: Don't add new ones
	for my $user ( split /[\s,]+/, $users ) {
	    push @{ $self->{USERS} }, lc $user;
	}
    }
    my @users = @{ $self->{USERS} };
    return wantarray ? @users : \@users;
}

sub Verify_parameters {
    my $self =		shift;

    my @required_parameters = REQ_PARAMETERS;
    return $self->SUPER::Verify_parameters( \@required_parameters );
}
#
# END: CLASS: Section::Group
########################################################################

########################################################################
# CLASS: Section::File
#
package Section::File;
use base qw(Section);
use Carp;

use constant REQ_PARAMETERS 	=> qw(Match Users Access);
use constant VALID_CASES	=> qw(match ignore);
use constant VALID_ACCESSES	=> qw(read-only read-write add-only no-delete no-add);

sub Match {
    my $self		= shift;
    my $match		= shift;

    if ( defined $match ) {
	$self->{MATCH} = $match;
    }

    return $self->{MATCH};
}

sub Access {
    my $self		= shift;
    my $access		= shift;

    if ( defined $access ) {
	$access = lc $access;
	my %valid_accesses;
	map { $valid_accesses{lc $_} = 1 } +VALID_ACCESSES;
	if ( not exists $valid_accesses{$access} ) {
	    croak qq(Invalid File access "$access");
	}
	$self->{ACCESS} = $access;
    }
    return $self->{ACCESS};
}

sub File {
    my $self		= shift;
    my $glob		= shift;

    if ( not defined $glob ) {
	croak qq(Matching glob file pattern required);
    }

    my $match = Section::glob2regex( $glob );
    return $self->Match( $match );
}

sub Case {
    my $self		= shift;
    my $case		= shift;

    $self->{CASE} = "match" if not exists $self->{CASE}; #Default
    if ( defined $case ) {
	$case = lc $case;
	my %valid_cases;
	map { $valid_cases{lc $_} = 1 } +VALID_CASES;
	if ( not exists $valid_cases{$case} ) {
	    croak qq(Invalid case "$case" passed to method);
	}
	$self->{CASE} = $case;
    }
    return $self->{CASE};
}

sub Users {
    my $self		= shift;
    my $users		= shift;

    if ( defined $users ) {
	my @users = map { lc } split /[\s,]+/, $users; #Lower case!
	$self->{USERS} = \@users;
    }

    my @users = @{ $self->{USERS} };
    return wantarray ? @users : \@users;
}

sub Verify_parameters {
    my $self =		shift;

    my @required_parameters =	REQ_PARAMETERS;
    return $self->SUPER::Verify_parameters( \@required_parameters );
}
#
# END: CLASS Section::Group
########################################################################

########################################################################
# CLASS: Section::Property
#
package Section::Property;
use Carp;
use base qw(Section);

use constant REQ_PARAMETERS	=> qw(Match Property Value Type);
use constant VALID_TYPES	=> qw(string number regex);
use constant VALID_CASES	=> qw(match ignore);

sub Match {
    my $self		= shift;
    my $match		= shift;

    if ( defined $match ) {
	$self->{MATCH} = $match;
    }
    return $self->{MATCH};
}

sub File {
    my $self		= shift;
    my $glob		= shift;

    if ( not defined $glob ) {
	croak qq(Method is only for setting not fetching);
    }

    my $match = Section::glob2regex($glob);
    return $self->Match( $match );
}

sub Case {
    my $self		= shift;
    my $case		= shift;

    $self->{CASE} = "match" if not exists $self->{CASE};	#Default;
    if ( defined $case ) {
	my %valid_cases;
	my $case = lc $case;
	map { $valid_cases{lc $_} = 1 } @{[VALID_CASES]};
	if ( not exists $valid_cases{$case} ) {
	    croak qq(Invalid case "$case");
	}
	$self->{CASE} = $case;
    }
    return $self->{CASE};
}

sub Property {
    my $self		= shift;
    my $property	= shift;

    if ( defined $property ) {
	$self->{PROPERTY} = $property;
    }
    return $self->{PROPERTY};
}

sub Value {
    my $self		= shift;
    my $value		= shift;

    if ( defined $value ) { 
	$self->{VALUE} = $value;
    }
    return $self->{VALUE};
}

sub Type {
    my $self		= shift;
    my $type		= shift;

    if ( defined $type ) {
	my $type = lc $type;
	my %valid_types;
	map { $valid_types{lc $_} = 1 } +VALID_TYPES;
	if ( not exists $valid_types{$type} ) {
	    croak qq(Invalid type of "$type" Property type passed);
	}
	$self->{TYPE} = $type;
    }
    return $self->{TYPE};
}

sub Verify_parameters {
    my $self =		shift;

    my @required_parameters = REQ_PARAMETERS;
    return $self->SUPER::Verify_parameters( \@required_parameters );
}
#
# END: Class: Section::Property
########################################################################

########################################################################
# CLASS: Section::Revprop
#
package Section::Revprop;
use Carp;
use base qw(Section);

use constant REQ_PARAMETERS	=> qw(Property Value Type);
use constant VALID_TYPES	=> qw(string number regex);

sub Property {
    my $self		= shift;
    my $property	= shift;

    if ( defined $property ) {
	$self->{PROPERTY} = $property;
    }
    return $self->{PROPERTY};
}

sub Value {
    my $self		= shift;
    my $value		= shift;

    if ( defined $value ) { 
	$self->{VALUE} = $value;
    }
    return $self->{VALUE};
}

sub Type {
    my $self		= shift;
    my $type		= shift;

    if ( defined $type ) {
	my $type = lc $type;
	my %valid_types;
	map { $valid_types{lc $_} = 1 } +VALID_TYPES;
	if ( not exists $valid_types{$type} ) {
	    croak qq(Invalid type of "$type" Property type passed);
	}
	$self->{TYPE} = $type;
    }
    return $self->{TYPE};
}

sub Verify_parameters {
    my $self =		shift;

    my @required_parameters = REQ_PARAMETERS;
    return $self->SUPER::Verify_parameters( \@required_parameters );
}
#
# END: Class: Section::Revprop
########################################################################

########################################################################
# Class: Section::Ban
# 
package Section::Ban;
use base qw(Section);

use Carp;

use constant REQ_PARAMETERS	=> qw(Match);
use constant VALID_CASES	=> qw(match ignore);

sub File {
    my $self		= shift;
    my $glob		= shift;

    my $match = Section::glob2regex( $glob );
    $self->Match( $match );
}

sub Match {
    my $self		= shift;
    my $match		= shift;

    if ( defined $match ) {
	$self->{MATCH} = $match;
    }
    return $self->{MATCH};
}

sub Case {
    my $self		= shift;
    my $case		= shift;

    $self->{CASE} = "match" if not exists $self->{CASE};	#Default;
    if ( defined $case ) {
	$case = lc $case;
	my %valid_cases;
	map { $valid_cases{lc $_} = 1 } +VALID_CASES;
	if ( not exists $valid_cases{$case} ) {
	    croak qq(Invalid case "$case" passed to method);
	}
	$self->{CASE} = $case;
    }
    return $self->{CASE};
}

sub Verify_parameters {
    my $self =		shift;

    my @required_parameters = REQ_PARAMETERS;
    return $self->SUPER::Verify_parameters( \@required_parameters );
}
#
# END: Class Section::Ban
########################################################################

########################################################################
# Class Section::Ldap
#
package Section::Ldap;
use Data::Dumper;
use Carp;
use base qw(Section);

use constant REQ_PARAMETERS	=> qw(ldap base);

use constant {
    DEFAULT_NAME_ATTR	=> "sAMAccountName",
    DEFAULT_GROUP_ATTR	=> "memberOf",
    DEFAULT_TIMEOUT	=> 5,
};

BEGIN {
    eval { require Net::LDAP; };
    our $ldap_available = 1 if not $@;
}
our $ldap_available;

sub Description {
    my $self		= shift;
    my $description	= shift;

    if ( not $ldap_available ) {
	carp qq(ERROR: Need to install Perl module Net::LDAP\n)
	. qq(       to be able to use LDAP groups);
	croak qq(Need to install Perl module Net::LDAP);
    }
    return $self->SUPER::Description( $description );
}


sub Ldap {
    my $self		= shift;

    if ( not $self->Description ) {
	croak qq(Missing description which contains the LDAP server list);
    }

    my @ldaps = split /[\s,]+/, $self->Description;	
    return wantarray ? @ldaps : \@ldaps;
}

sub Username_attr {
    my $self		= shift;
    my $username_attr	= shift;

    if ( defined $username_attr ) {
	$self->{USER_NAME_ATTR} = $username_attr;
    }

    if ( not exists $self->{USER_NAME_ATTR} ) {
	$self->{USER_NAME_ATTR} = DEFAULT_NAME_ATTR;
    }
    return $self->{USER_NAME_ATTR};
}

sub Group_attr {
    my $self		= shift;
    my $group_attr	= shift;

    if ( defined $group_attr ) {
	$self->{GROUP_ATTR} = $group_attr;
    }
    if ( not exists $self->{GROUP_ATTR} ) {
	$self->{GROUP_ATTR} = DEFAULT_GROUP_ATTR;
    }
    return $self->{GROUP_ATTR};
}

sub Base {
    my $self		= shift;
    my $base		= shift;

    if ( defined $base) {
	$self->{BASE} = $base;
    }
    return $self->{BASE};
}

sub User_dn {
    my $self		= shift;
    my $user_dn		= shift;

    if ( defined $user_dn ) {
	$self->{USER_DN} = $user_dn;
    }
    return $self->{USER_DN};
}

sub Password {
    my $self		= shift;
    my $password	= shift;

    if ( defined $password ) {
	$self->{PASSWORD} = $password;
    }
    return $self->{PASSWORD};
}

sub Search_base {
    my $self		= shift;
    my $search_base	= shift;

    if ( defined $search_base ) {
	$self->{SEARCH_BASE} = $search_base;
    }
    return $self->{SEARCH_BASE};
}

sub Timeout {
    my $self		= shift;
    my $timeout		= shift;

    if ( defined $timeout ) {
	if ( $timeout =~ /^\d+$/ ) {
	    croak qq(Timeout value for ldap server must be an integer);
	}
	$self->{TIMEOUT} = $timeout;
    }

    if ( not exists $self->{TIMEOUT} ) {
	$self->{TIMEOUT} = DEFAULT_TIMEOUT;
    }
    return $self->{TIMEOUT};
}

sub Ldap_groups {
    my $self		= shift;
    my $user		= shift;

    my $ldap_servers	= $self->Ldap;
    my $user_dn		= $self->User_dn;
    my $password	= $self->Password;
    my $timeout		= $self->Timeout;

    my $username_attr	= $self->Username_attr;
    my $group_attr	= $self->Group_attr;

    if ( not defined $user ) {
	croak qq(Need to pass in a user name);
    }

    #
    # Create LDAP Object
    #
    my $ldap = Net::LDAP->new( $ldap_servers,
	timeout => $timeout,
	onerror => "die"
    );
    if ( not defined $ldap ) {
	croak qq(Could not connect to LDAP servers:)
	. join( ", ", @{ $ldap_servers } ) . qq( Timeout = $timeout );
    }
    #
    # Try a bind
    #
    my $message;
    eval {
	if ( $user_dn and $password ) {
	    $message = $ldap->bind( $user_dn, password => $password );
	}
	elsif ( $user_dn and not $password ) {
	    $message = $ldap->bind( $user_dn );
	}
	else {
	    $message = $ldap->bind;
	}
    };
    if ( $@ ) {
	no warnings qw(uninitialized);
	croak qq(Could not "bind" to LDAP server.) 
	. qq( User DN: "$user_dn" Password: "$password");
    }

    #
    # Search
    #

    my $search_base	= $self->Search_base;
    my $base_dn		= $self->Base;
    my $search;
    if ( not $base_dn ) {
	croak qq(Missing Base DN definition. Cannot do LDAP Search for groups);
    }
    eval {
	if ( $search_base ) {
	    $search = $ldap->search(
		base => $base_dn,
		basename => $search_base,
		filter => "($username_attr=$user)",
	    );
	}
	else {
	    $search = $ldap->search(
		base => $base_dn,
		filter => "($username_attr=$user)"
	    );
	}
    };
    if ( $@ ) {
	croak qq(Search of LDAP tree failed ($username_attr=$user));
    }

    #
    # Get the Entry
    #
    my $entry = $search->pop_entry;	#Should only return a single entry

    #
    # Get the attribute of that entry
    #

    my @groups;
    for my $group ( $entry->get_value( $group_attr ) ) {
	$group =~ s/cn=(.+?),.*/\L$1\U/i;  	#Just the "CN" value
	push @groups, $group;
    }
    return wantarray ? @groups : \@groups;
}

sub Verify_parameters {
    my $self =		shift;

    my @required_parameters = REQ_PARAMETERS;
    return $self->SUPER::Verify_parameters( \@required_parameters );
}
#
# END: Class: Section::Ldap
########################################################################

########################################################################
# Class Parse_error;
#
package Parse_error;
use Carp;

sub new {
    my $class		= shift;
    my $description	= shift;
    my $control_file	= shift;
    my $line_number	= shift;

    my $self = {};
    bless $self, $class;

    $self->Description($description);
    $self->Control_file($control_file);
    $self->Line_number($line_number);
    return $self;
}

sub Description {
    my $self		= shift;
    my $description	= shift;

    if ( defined $description ) {
	$self->{DESCRIPTION} = $description;
    }
    return $self->{DESCRIPTION};
}

sub Control_file {
    my $self		= shift;
    my $control_file	= shift;

    if ( defined $control_file ) {
	if ( not ref $control_file eq "Control_file" ) {
	    croak qq( Control file parameter must be a Control_file object);
	}
	$self->{CONTROL_FILE} = $control_file;
    }
    return $self->{CONTROL_FILE};
}

sub Line_number {
    my $self		= shift;
    my $line_number	= shift;

    if ( defined $line_number ) {
	if ( $line_number !~ /^\d+$/ ) {
	    croak qq(Line number must be an integer);
	}
	$self->{LINE_NUMBER} = $line_number - 1;
    }
    return $self->{LINE_NUMBER};
}

sub Get_error { 
    my $self		= shift;

    my $control_file	= $self->Control_file;
    my $file_name 	= $control_file->Location;
    my $location	= $control_file->Type;
    my @file_contents	= $control_file->Content;

    #
    # You need to push the line that has the error
    # and the entire section which may mean lines
    # before and after the error
    #

    my $line_number = $self->Line_number;
    my $line = $file_contents[$line_number];
    my @section_lines;
    push @section_lines, "-> $line";
    #
    # Unshift lines before the error until at beginning
    # of the control file, or at a section heading
    #
    while ( $line_number != 0
	    and $file_contents[$line_number] !~ /^\s*\[/ ) {
	$line_number--;
	my $line = $file_contents[$line_number];
	unshift @section_lines, "   $line";
    }
    #
    # Push lines after error until next section
    # hearder or the end of file
    #
    $line_number = $self->Line_number + 1;
    while ( $line_number <= $#file_contents
	    and $file_contents[$line_number] !~ /^\s*\[/ ) {
	my $line = $file_contents[$line_number];
	$line_number++;
	next if not $line;
	push @section_lines, "   $line";

    }
    #
    # Now generate the error message
    #

    my $description =  "ERROR: In parsing Control File";
    $description .= qq( "$file_name" ($location));
    $description .= " Line# " . $self->Line_number . "\n";
    $description .= "    " . $self->Description . "\n";
    for my $line ( @section_lines ) {
	$description .= "    $line\n";
    }
    return $description;
}
#
# END: Class: Parse_error
########################################################################

########################################################################
# Class Section_group
#
package Section_group;
use Carp;

sub new	{
    my $class		= shift;

    my $self = {};
    bless $self, $class;
    return $self;
}

sub Add {
    my $self		= shift;
    my $section		= shift;

    if ( not defined $section ) {
	croak qq(Need to pass in a "Section" object type);
    }

    if ( not $section->isa("Section") ) {
	croak qq(Can only add "Section" object types);
    }

    my $section_class = ref $section;
    ( my $section_type = $section_class )  =~ s/.*:://;

    $section_type = ucfirst lc $section_type;
    $self->$section_type($section);
}

sub Sections {
    my $self		= shift;

    my @sections = qw(Group File Property Revprop Ban Ldap);
    return wantarray ? @sections : \@sections;
}

sub Group {
    my $self		= shift;
    my $section		= shift;

    if ( defined $section ) {
	push @{ $self->{GROUP} }, $section;
    }
    my @groups = @{ $self->{GROUP} };
    return wantarray ? @groups : \@groups;
}

sub File {
    my $self		= shift;
    my $section		= shift;

    if ( defined $section ) {
	push @{ $self->{FILE} }, $section;
    }
    my @files = @{ $self->{FILE} };
    return wantarray ? @files : \@files;
}

sub Property {
    my $self		= shift;
    my $section		= shift;

    if ( defined $section ) {
	push @{ $self->{PROPERTY} }, $section;
    }
    my @properties = @{ $self->{PROPERTY} };
    return wantarray ? @properties : \@properties;
}

sub Revprop {
    my $self		= shift;
    my $section		= shift;

    if ( defined $section ) {
	push @{ $self->{REVPROP} }, $section;
    }
    my @rev_props = @{ $self->{REVPROP} };
    return wantarray ? @rev_props : \@rev_props;
}

sub Ban {
    my $self		= shift;
    my $section		= shift;

    if ( defined $section ) {
	push @{ $self->{BAN} }, $section;
    }
    my @bans = @{ $self->{BAN} };
    return wantarray ? @bans : \@bans;
}
sub Ldap {
    my $self		= shift;
    my $section		= shift;

    if ( defined $section ) {
	push @{ $self->{LDAP} }, $section;
    }
    my @ldaps = @{ $self->{LDAP} };
    return wantarray ? @ldaps : \@ldaps;
}
#
########################################################################

########################################################################
# CLASS Violation
#
package Violation;

sub new {
    my $class		= shift;
    my $file		= shift;
    my $error		= shift;
    my $policy		= shift;

    my $self = {};
    bless $self, $class;

    $self->File($file);
    $self->Error($error);
    $self->Policy($policy);
    return $self;
}

sub File {
    my $self		= shift;
    my $file		= shift;

    if ( defined $file ) {
	$self->{FILE} = $file;
    }
    return $self->{FILE};
}

sub Policy {
    my $self		= shift;
    my $policy		= shift;

    if ( defined $policy ) {
	$self->{POLICY} = $policy;
    }
    return $self->{POLICY};
}

sub Error {
    my $self		= shift;
    my $error		= shift;

    if ( defined $error ) {
	$self->{ERROR} = $error;
    }
    return $self->{ERROR};
}
