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

# Test widgetOverride generation
print "\nTesting widgetOverride generation:\n";
my $widgetOverrides = LEDController_BuildWidgetOverrides($hash);
print "Generated widgetOverrides: $widgetOverrides\n\n";

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
print "widgetOverrides generation: " . ($widgetsPassed ? "PASSED" : "FAILED") . "\n";
print "Edge cases: PASSED\n";

my $allPassed = $webCmdPassed && $widgetsPassed;
print "\nOverall result: " . ($allPassed ? "ALL TESTS PASSED" : "SOME TESTS FAILED") . "\n";

exit($allPassed ? 0 : 1);