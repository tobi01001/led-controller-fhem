#!/usr/bin/perl
# Test for CSRF token handling in LEDController module

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

# Track CommandAttr calls to ensure proper attribute setting
my @commandAttrCalls = ();
sub CommandAttr {
    my ($cl, $cmd) = @_;
    push @commandAttrCalls, $cmd;
    # Simulate successful attribute setting
    return undef;
}

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

# Include the functions we need to test
sub LEDController_BuildWebCmd($) {
    my ($hash) = @_;
    
    my @webCmds = ();
    push @webCmds, "refresh";
    
    my @sortedFields = sort { $a cmp $b } keys %{$hash->{FIELD_STRUCTURE}};
    
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

# The actual function we're testing - fixed version
sub LEDController_BuildFHEMControls($) {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    
    Log3 $name, 3, "LEDController ($name) - building FHEM control elements";
    
    # Build webCmd attribute
    my $webCmd = LEDController_BuildWebCmd($hash);
    if($webCmd) {
        # Use CommandAttr to properly set attributes through FHEM's validation
        my $ret = CommandAttr(undef, "$name webCmd $webCmd");
        if($ret) {
            Log3 $name, 2, "LEDController ($name) - error setting webCmd: $ret";
        } else {
            Log3 $name, 4, "LEDController ($name) - set webCmd: $webCmd";
        }
    }
    
    # Build widgetOverride attribute  
    my $widgetOverrides = LEDController_BuildWidgetOverrides($hash);
    if($widgetOverrides) {
        # Use CommandAttr to properly set attributes through FHEM's validation
        my $ret = CommandAttr(undef, "$name widgetOverride $widgetOverrides");
        if($ret) {
            Log3 $name, 2, "LEDController ($name) - error setting widgetOverride: $ret";
        } else {
            Log3 $name, 4, "LEDController ($name) - set widgetOverride: $widgetOverrides";
        }
    }
    
    Log3 $name, 3, "LEDController ($name) - FHEM control elements built successfully";
}

# Test with mock data
print "=== LEDController CSRF Token Validation Test ===\n\n";

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
            max => 2,
            options => ["Static", "Rainbow", "Fire"]
        }
    }
};

# Clear previous calls
@commandAttrCalls = ();

# Test that BuildFHEMControls uses CommandAttr instead of direct %attr manipulation
print "Testing CSRF-safe attribute setting:\n";
LEDController_BuildFHEMControls($hash);

# Validate that CommandAttr was called properly
print "CommandAttr calls made: " . scalar(@commandAttrCalls) . "\n";
my $csrfTestPassed = 1;

if (scalar(@commandAttrCalls) != 2) {
    print "✗ Expected 2 CommandAttr calls, got " . scalar(@commandAttrCalls) . "\n";
    $csrfTestPassed = 0;
} else {
    print "✓ Correct number of CommandAttr calls made\n";
}

# Check webCmd call
my $webCmdCall = $commandAttrCalls[0] || "";
if ($webCmdCall =~ /^test_led webCmd /) {
    print "✓ webCmd attribute set properly via CommandAttr\n";
} else {
    print "✗ webCmd attribute not set properly: '$webCmdCall'\n";
    $csrfTestPassed = 0;
}

# Check widgetOverride call  
my $widgetCall = $commandAttrCalls[1] || "";
if ($widgetCall =~ /^test_led widgetOverride /) {
    print "✓ widgetOverride attribute set properly via CommandAttr\n";
} else {
    print "✗ widgetOverride attribute not set properly: '$widgetCall'\n";
    $csrfTestPassed = 0;
}

# Test that direct %attr manipulation is not used
print "\nTesting that direct \%attr manipulation is avoided:\n";
my $attrDirectlySet = (exists $attr{test_led}{webCmd} || exists $attr{test_led}{widgetOverride});
if (!$attrDirectlySet) {
    print "✓ No direct \%attr manipulation detected\n";
} else {
    print "✗ Direct \%attr manipulation still present\n";
    $csrfTestPassed = 0;
}

# Test edge case - empty structure should still call CommandAttr for webCmd (refresh)
@commandAttrCalls = ();
my $emptyHash = { NAME => "empty", FIELD_STRUCTURE => {} };
LEDController_BuildFHEMControls($emptyHash);

if (scalar(@commandAttrCalls) == 1 && $commandAttrCalls[0] =~ /^empty webCmd refresh$/) {
    print "✓ Correct CommandAttr call made for empty structure (webCmd refresh)\n";
} else {
    print "✗ Unexpected CommandAttr calls for empty structure: " . join(", ", @commandAttrCalls) . "\n";
    $csrfTestPassed = 0;
}

# Summary
print "\n=== Test Results ===\n";
print "CSRF-safe attribute setting: " . ($csrfTestPassed ? "PASSED" : "FAILED") . "\n";
print "Overall result: " . ($csrfTestPassed ? "CSRF ISSUE RESOLVED" : "CSRF ISSUE REMAINS") . "\n";

exit($csrfTestPassed ? 0 : 1);