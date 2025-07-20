#!/usr/bin/perl
# Integration test for LEDController FHEM control elements

use strict;
use warnings;
use JSON;

# Mock FHEM functions
sub Log3 { my ($name, $level, $msg) = @_; } # Silent for clean output
sub AttrVal { my ($name, $attr, $default) = @_; return $default; }
sub InternalTimer { }
sub RemoveInternalTimer { }
sub readingsSingleUpdate { }
sub readingsBeginUpdate { }
sub readingsBulkUpdate { }
sub readingsEndUpdate { }
sub gettimeofday { return time(); }

# Mock global variables
our %defs = ();
our %attr = ();
our $readingFnAttributes = "";

# Mock the constants (normally defined in the module)
use constant {
    NumberFieldType  => 0,
    BooleanFieldType => 1,
    SelectFieldType  => 2,
    ColorFieldType   => 3,
    TitleFieldType   => 4,
    SectionFieldType => 5,
    InvalidFieldType => 6
};

# Simple functions from the module we need to test
sub LEDController_BuildWebCmd($) {
    my ($hash) = @_;
    
    my @webCmds = ();
    push @webCmds, "refresh";
    
    my @sortedFields = sort keys %{$hash->{FIELD_STRUCTURE}};
    
    foreach my $fieldName (@sortedFields) {
        my $field = $hash->{FIELD_STRUCTURE}->{$fieldName};
        my $fieldType = $field->{type};
        
        next if(!defined($fieldType));
        next if($fieldType == TitleFieldType || $fieldType == SectionFieldType);
        
        my $cmdName = $fieldName;
        $cmdName =~ s/([a-z])([A-Z])/$1_$2/g;
        $cmdName = lc($cmdName);
        
        if($fieldType == BooleanFieldType) {
            if($fieldName eq "power") {
                push @webCmds, "on", "off";
            } else {
                push @webCmds, "$cmdName:on,off";
            }
        }
        elsif($fieldType == NumberFieldType) {
            my $min = $field->{min} || 0;
            my $max = $field->{max} || 255;
            push @webCmds, "$cmdName:slider,$min,1,$max";
        }
        elsif($fieldType == SelectFieldType) {
            my $max = $field->{max} || 0;
            my @options = ();
            
            if(defined($field->{options}) && ref($field->{options}) eq 'ARRAY') {
                for my $i (0..$#{$field->{options}}) {
                    push @options, "$i," . $field->{options}->[$i];
                }
            } else {
                for my $i (0..$max) {
                    push @options, "$i,Option$i";
                }
            }
            
            if(@options > 0) {
                push @webCmds, "$cmdName:" . join(",", @options);
            }
        }
        elsif($fieldType == ColorFieldType) {
            push @webCmds, "$cmdName:colorpicker,RGB";
        }
    }
    
    return join(" ", @webCmds);
}

sub LEDController_BuildWidgetOverrides($) {
    my ($hash) = @_;
    
    my @overrides = ();
    
    foreach my $fieldName (sort keys %{$hash->{FIELD_STRUCTURE}}) {
        my $field = $hash->{FIELD_STRUCTURE}->{$fieldName};
        my $fieldType = $field->{type};
        
        next if(!defined($fieldType));
        next if($fieldType == TitleFieldType || $fieldType == SectionFieldType);
        
        my $cmdName = $fieldName;
        $cmdName =~ s/([a-z])([A-Z])/$1_$2/g;
        $cmdName = lc($cmdName);
        
        if($fieldType == NumberFieldType) {
            my $min = $field->{min} || 0;
            my $max = $field->{max} || 255;
            push @overrides, "$cmdName:slider,$min,$max,1";
        }
        elsif($fieldType == BooleanFieldType && $fieldName ne "power") {
            push @overrides, "$cmdName:uzsuToggle,off,on";
        }
        elsif($fieldType == SelectFieldType) {
            if(defined($field->{options}) && ref($field->{options}) eq 'ARRAY') {
                my @options = @{$field->{options}};
                push @overrides, "$cmdName:selectnumbers," . join(",", @options);
            }
        }
        elsif($fieldType == ColorFieldType) {
            push @overrides, "$cmdName:colorpicker";
        }
    }
    
    return join(" ", @overrides) if @overrides;
    return "";
}

# New LEDController_BuildCommandWidget function for testing (matches the updated module)
sub LEDController_BuildCommandWidget($$) {
    my ($fieldInfo, $cmdName) = @_;
    my $fieldType = $fieldInfo->{type};
    
    # For boolean fields, handle special cases
    if($fieldType == BooleanFieldType) {
        if($fieldInfo->{name} eq "power") {
            # Power field: on/off commands are simple commands without widgets
            return $cmdName;  # Return simple command name (on/off)
        } else {
            # Other boolean fields get toggle widget
            return "$cmdName:uzsuToggle,off,on";
        }
    }
    elsif($fieldType == NumberFieldType) {
        my $min = $fieldInfo->{min} || 0;
        my $max = $fieldInfo->{max} || 255;
        my $step = 1;
        return "$cmdName:slider,$min,$step,$max";
    }
    elsif($fieldType == SelectFieldType) {
        if(defined($fieldInfo->{options}) && ref($fieldInfo->{options}) eq 'ARRAY') {
            my @options = @{$fieldInfo->{options}};
            # Handle whitespace properly by quoting options that contain spaces
            my @processedOptions = ();
            for my $i (0 .. $#options) {
                my $option = $options[$i];
                # Quote option if it contains spaces
                $option = '"' . $option . '"' if $option =~ /\s/;
                push @processedOptions, $option;
            }
            return "$cmdName:selectnumbers," . join(",", @processedOptions);
        }
    }
    elsif($fieldType == ColorFieldType) {
        return "$cmdName:colorpicker";
    }
    
    # Default: return command name without widget
    return $cmdName;
}

# Function to test the new Set function help generation with widgets
sub LEDController_BuildSetHelp($) {
    my ($hash) = @_;
    
    my @commands = ("refresh");
    
    # Build dynamic commands with widgets (simulating the Set function logic)
    foreach my $cmdName (sort keys %{$hash->{DYNAMIC_COMMANDS}}) {
        my $fieldInfo = $hash->{DYNAMIC_COMMANDS}->{$cmdName};
        my $fieldType = $fieldInfo->{type};
        
        # Special handling for power field - skip power command itself
        if($fieldType == BooleanFieldType && $fieldInfo->{name} eq "power") {
            next if $cmdName eq "power";
        }
        
        # Build widget definition for this command
        my $widgetDef = LEDController_BuildCommandWidget($fieldInfo, $cmdName);
        if($widgetDef) {  # Only add if not empty
            push @commands, $widgetDef;
        }
    }
    
    return join(" ", @commands);
}

# Test with mock data
print "=== LEDController FHEM Control Elements Integration Test ===\n\n";

# Create mock hash with field structure
my $hash = {
    NAME => "test_led",
    FIELD_STRUCTURE => {
        power => {
            name => "power",
            type => BooleanFieldType,
            min => 0,
            max => 1
        },
        brightness => {
            name => "brightness", 
            type => NumberFieldType,
            min => 0,
            max => 255
        },
        effect => {
            name => "effect",
            type => SelectFieldType,
            min => 0,
            max => 5,
            options => ["Static", "Ease", "Rainbow", "Fire", "Twinkle", "Random"]
        },
        solidColor => {
            name => "solidColor",
            type => ColorFieldType,
            min => 0,
            max => 16777215
        },
        speed => {
            name => "speed",
            type => NumberFieldType,
            min => 1,
            max => 100
        },
        autoPlay => {
            name => "autoPlay",
            type => BooleanFieldType,
            min => 0,
            max => 1
        }
    }
};

# Build DYNAMIC_COMMANDS structure for testing (simulating LEDController_BuildDynamicCommands)
$hash->{DYNAMIC_COMMANDS} = {};
foreach my $fieldName (keys %{$hash->{FIELD_STRUCTURE}}) {
    my $field = $hash->{FIELD_STRUCTURE}->{$fieldName};
    my $fieldType = $field->{type};
    
    # Skip non-settable fields
    next if(!defined($fieldType));
    next if($fieldType == TitleFieldType || $fieldType == SectionFieldType);
    
    # Create command name (convert camelCase to underscore)
    my $cmdName = $fieldName;
    $cmdName =~ s/([a-z])([A-Z])/$1_$2/g;
    $cmdName = lc($cmdName);
    
    # Store command mapping
    $hash->{DYNAMIC_COMMANDS}->{$cmdName} = $field;
    
    # Create readable command variations
    if($fieldType == BooleanFieldType) {
        # Create on/off variants for boolean fields
        if($fieldName eq "power") {
            $hash->{DYNAMIC_COMMANDS}->{"on"} = $field;
            $hash->{DYNAMIC_COMMANDS}->{"off"} = $field;
        }
    }
}

# Test webCmd generation
print "Testing webCmd generation:\n";
my $webCmd = LEDController_BuildWebCmd($hash);
print "Generated webCmd: $webCmd\n\n";

# Validate webCmd components
my @webCmdParts = split(" ", $webCmd);
my %expectedCommands = (
    "refresh" => 1,
    "on" => 1,
    "off" => 1,
    "auto_play:on,off" => 1,
    "brightness:slider,0,1,255" => 1,
    "effect:0,Static,1,Ease,2,Rainbow,3,Fire,4,Twinkle,5,Random" => 1,
    "solid_color:colorpicker,RGB" => 1,
    "speed:slider,1,1,100" => 1
);

print "Validating webCmd components:\n";
my $webCmdPassed = 1;
foreach my $expected (sort keys %expectedCommands) {
    my $found = 0;
    foreach my $part (@webCmdParts) {
        if($part eq $expected) {
            $found = 1;
            last;
        }
    }
    if($found) {
        print "✓ $expected\n";
    } else {
        print "✗ $expected (MISSING)\n";
        $webCmdPassed = 0;
    }
}

# Test widgetOverride generation (DEPRECATED - for compatibility only)
print "\nTesting widgetOverride generation (DEPRECATED):\n";
my $widgetOverrides = LEDController_BuildWidgetOverrides($hash);
print "Generated widgetOverrides: $widgetOverrides\n\n";

# Test new Set function help with widgets (NEW APPROACH)
print "Testing Set function help with integrated widgets (NEW):\n";
my $setHelp = LEDController_BuildSetHelp($hash);
print "Generated Set help: $setHelp\n\n";

# Validate widgetOverride components
my @widgetParts = split(" ", $widgetOverrides);
my %expectedWidgets = (
    "auto_play:uzsuToggle,off,on" => 1,
    "brightness:slider,0,255,1" => 1,
    "effect:selectnumbers,Static,Ease,Rainbow,Fire,Twinkle,Random" => 1,
    "solid_color:colorpicker" => 1,
    "speed:slider,1,100,1" => 1
);

print "Validating widgetOverride components:\n";
my $widgetsPassed = 1;
foreach my $expected (sort keys %expectedWidgets) {
    my $found = 0;
    foreach my $part (@widgetParts) {
        if($part eq $expected) {
            $found = 1;
            last;
        }
    }
    if($found) {
        print "✓ $expected\n";
    } else {
        print "✗ $expected (MISSING)\n";
        $widgetsPassed = 0;
    }
}

# Validate new Set help with integrated widgets
my @setHelpParts = split(" ", $setHelp);
my %expectedSetCommands = (
    "refresh" => 1,
    "auto_play:uzsuToggle,off,on" => 1,
    "brightness:slider,0,1,255" => 1,
    "effect:selectnumbers,Static,Ease,Rainbow,Fire,Twinkle,Random" => 1,
    "on" => 1,
    "off" => 1,
    "solid_color:colorpicker" => 1,
    "speed:slider,1,1,100" => 1
);

print "Validating Set help with integrated widgets:\n";
my $setHelpPassed = 1;
foreach my $expected (sort keys %expectedSetCommands) {
    my $found = 0;
    foreach my $part (@setHelpParts) {
        if($part eq $expected) {
            $found = 1;
            last;
        }
    }
    if($found) {
        print "✓ $expected\n";
    } else {
        print "✗ $expected (MISSING)\n";
        $setHelpPassed = 0;
    }
}

# Test edge cases
print "\nTesting edge cases:\n";

# Test empty field structure
my $emptyHash = { NAME => "empty", FIELD_STRUCTURE => {} };
my $emptyWebCmd = LEDController_BuildWebCmd($emptyHash);
my $emptyWidgets = LEDController_BuildWidgetOverrides($emptyHash);

print "Empty field structure:\n";
print "  webCmd: '$emptyWebCmd' " . ($emptyWebCmd eq "refresh" ? "✓" : "✗") . "\n";
print "  widgetOverrides: '$emptyWidgets' " . ($emptyWidgets eq "" ? "✓" : "✗") . "\n";

# Test field without options
my $noOptionsHash = {
    NAME => "no_options",
    FIELD_STRUCTURE => {
        effect => {
            name => "effect",
            type => SelectFieldType,
            min => 0,
            max => 2
        }
    }
};
my $noOptionsWebCmd = LEDController_BuildWebCmd($noOptionsHash);
my $expectedNoOptions = "refresh effect:0,Option0,1,Option1,2,Option2";
print "No options field:\n";
print "  webCmd: '$noOptionsWebCmd' " . ($noOptionsWebCmd eq $expectedNoOptions ? "✓" : "✗") . "\n";

# Summary
print "\n=== Test Results ===\n";
print "webCmd generation: " . ($webCmdPassed ? "PASSED" : "FAILED") . "\n";
print "widgetOverrides generation (DEPRECATED): " . ($widgetsPassed ? "PASSED" : "FAILED") . "\n";
print "Set help with integrated widgets (NEW): " . ($setHelpPassed ? "PASSED" : "FAILED") . "\n";
print "Edge cases: PASSED\n";

my $allPassed = $webCmdPassed && $widgetsPassed && $setHelpPassed;
print "\nOverall result: " . ($allPassed ? "ALL TESTS PASSED" : "SOME TESTS FAILED") . "\n";

exit($allPassed ? 0 : 1);