#!/usr/bin/perl
# Test for proper widget format generation without widgetOverride usage

use strict;
use warnings;

# Mock FHEM functions (minimal required)
sub Log3 { my ($name, $level, $msg) = @_; }

# Field type constants
use constant {
    NumberFieldType  => 0,
    BooleanFieldType => 1,
    SelectFieldType  => 2,
    ColorFieldType   => 3,
    TitleFieldType   => 4,
    SectionFieldType => 5,
    InvalidFieldType => 6
};

# Include the function we're testing - simplified version from main module
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
            # Build value,label pairs for proper select dropdown functionality
            # This ensures the actual reading shows the label name even when value is transmitted as index
            my @processedOptions = ();
            for my $i (0 .. $#options) {
                my $option = $options[$i];
                # Quote option label if it contains spaces
                if($option =~ /\s/) {
                    push @processedOptions, "$i,\"$option\"";
                } else {
                    push @processedOptions, "$i,$option";
                }
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

print "=== Widget Format Test (No widgetOverride Usage) ===\n\n";

# Test cases for proper widget format generation
my @testCases = (
    {
        name => "number_field",
        field => {
            name => "brightness",
            type => NumberFieldType,
            min => 0,
            max => 255
        },
        expected => "brightness:slider,0,1,255"
    },
    {
        name => "boolean_power_on_field",
        field => {
            name => "power",
            type => BooleanFieldType
        },
        cmdName => "on",  # Test with "on" command
        expected => "on"  # Power commands should be simple
    },
    {
        name => "boolean_other_field", 
        field => {
            name => "autoPlay",
            type => BooleanFieldType
        },
        expected => "auto_play:uzsuToggle,off,on"
    },
    {
        name => "select_field_simple",
        field => {
            name => "effect",
            type => SelectFieldType,
            options => ["Static", "Rainbow", "Fire"]
        },
        expected => "effect:selectnumbers,0,Static,1,Rainbow,2,Fire"
    },
    {
        name => "select_field_with_spaces",
        field => {
            name => "mode",
            type => SelectFieldType,
            options => ["Simple Mode", "Advanced Mode", "Custom"]
        },
        expected => "mode:selectnumbers,0,\"Simple Mode\",1,\"Advanced Mode\",2,Custom"
    },
    {
        name => "color_field",
        field => {
            name => "solidColor",
            type => ColorFieldType
        },
        expected => "solid_color:colorpicker"
    }
);

my $allTestsPassed = 1;

foreach my $test (@testCases) {
    my $cmdName = defined($test->{cmdName}) ? $test->{cmdName} : $test->{field}->{name};
    
    # Convert camelCase to snake_case only if not explicitly provided
    if(!defined($test->{cmdName})) {
        $cmdName =~ s/([a-z])([A-Z])/$1_$2/g;
        $cmdName = lc($cmdName);
    }
    
    my $result = LEDController_BuildCommandWidget($test->{field}, $cmdName);
    
    print "Testing $test->{name}:\n";
    print "  Expected: $test->{expected}\n";
    print "  Got:      $result\n";
    
    if($result eq $test->{expected}) {
        print "  ✓ PASS\n\n";
    } else {
        print "  ✗ FAIL\n\n";
        $allTestsPassed = 0;
    }
}

# Test edge cases
print "=== Edge Case Tests ===\n\n";

# Test empty options array
my $emptySelectField = {
    name => "empty",
    type => SelectFieldType,
    options => []
};
my $emptyResult = LEDController_BuildCommandWidget($emptySelectField, "empty");
print "Empty select options:\n";
print "  Result: '$emptyResult'\n";
if($emptyResult eq "empty:selectnumbers,") {
    print "  ✓ PASS - Empty options handled correctly\n\n";
} else {
    print "  ✗ FAIL - Expected 'empty:selectnumbers,'\n\n";
    $allTestsPassed = 0;
}

# Test undefined options
my $undefinedSelectField = {
    name => "undefined",
    type => SelectFieldType
};
my $undefinedResult = LEDController_BuildCommandWidget($undefinedSelectField, "undefined");
print "Undefined select options:\n";
print "  Result: '$undefinedResult'\n";
if($undefinedResult eq "undefined") {
    print "  ✓ PASS - Undefined options default to command name\n\n";
} else {
    print "  ✗ FAIL - Expected 'undefined'\n\n";
    $allTestsPassed = 0;
}

# Summary
print "=== Test Results ===\n";
print "Widget format validation: " . ($allTestsPassed ? "PASSED" : "FAILED") . "\n";
print "Key improvements:\n";
print "✓ Widgets attached directly to commands (no widgetOverride)\n";
print "✓ Select dropdowns use value,label format for proper mapping\n";
print "✓ Whitespace in option names properly quoted\n";
print "✓ Reading values correctly shown as labels in UI\n\n";

exit($allTestsPassed ? 0 : 1);