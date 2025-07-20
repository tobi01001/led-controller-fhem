# FHEM LED Controller Module

This module provides FHEM integration for the [LED_Stripe_Dynamic_web_conf](https://github.com/tobi01001/LED_Stripe_Dynamic_web_conf) LED stripe controllers with **dynamic field structure discovery**.

## Features

- **Dynamic Command Generation**: Automatically discovers device capabilities and generates appropriate FHEM commands
- **FHEM Control Elements**: Automatically integrates widget definitions directly into commands for UI controls:
  - NumberFieldType → sliders with proper min/max ranges
  - BooleanFieldType → on/off toggle controls  
  - SelectFieldType → dropdown lists with field option names
  - ColorFieldType → color picker controls
- **Power State Indication**: FHEM state reading reflects actual power state (on/off)
- **WebSocket Connection Status**: Real-time connection status reading (connected/disconnected/failed)
- **Proper API Integration**: Uses the actual `/set` endpoint with query parameters, not fake REST endpoints
- **Section-Based Organization**: Matches the web interface structure with organized field sections
- **Field Type Validation**: Automatic validation based on field types (Number, Boolean, Select, Color)
- **Real-time WebSocket Updates**: Optional WebSocket support for live status updates
- **Full FHEM Integration**: Proper readings, attributes, and error handling

## How It Works

Unlike traditional FHEM modules with hardcoded commands, this module:

1. **Discovers Device Structure**: Connects to `/all` endpoint to get field definitions
2. **Builds Dynamic Commands**: Creates FHEM commands based on available fields
3. **Generates Control Elements**: Automatically integrates widget definitions directly into commands for proper UI controls
4. **Validates Parameters**: Uses field metadata (min/max, types) for validation
5. **Uses Real API**: Sends commands to `/set` endpoint with proper query parameters

## Installation

1. Copy `FHEM/98_LEDController.pm` to your FHEM modules directory (usually `/opt/fhem/FHEM/`)
2. Restart FHEM or reload the module: `reload 98_LEDController`

## Usage

### Define a device

```perl
define myLED LEDController 192.168.1.100:80
```

The module will automatically:
- Connect to the device
- Discover available fields and their properties
- Build appropriate FHEM commands
- Generate webCmd attributes for UI controls (sliders, toggles, dropdowns, color pickers)
- Integrate widget definitions directly into commands for enhanced UI controls
- Start regular status updates

### Control the LED stripe

```bash
# Basic control (available on most devices)
set myLED on                    # Turn on
set myLED off                   # Turn off
set myLED power on              # Alternative power control

# Dynamic commands based on device capabilities
set myLED brightness 128        # Set brightness (0-255)
set myLED effect 5              # Set effect by number
set myLED speed 1500            # Set effect speed
set myLED color_palette 3       # Set color palette
set myLED solid_color FF0000    # Set solid color (hex)

# Advanced features (if supported by device)
set myLED auto_play 1           # Enable auto mode change
set myLED segments 2            # Set number of segments
set myLED add_glitter 1         # Enable glitter effect
set myLED cooling 50            # Fire effect cooling
set myLED sparking 120          # Fire effect sparking

# Get available commands for your specific device
set myLED ?

# Refresh device capabilities
set myLED refresh
```

### Get information

```bash
# Get detailed device status
get myLED status

# Get all current field values
get myLED allvalues

# Get field structure (for debugging)
get myLED structure

# Get available effects/modes
get myLED modes

# Get available color palettes
get myLED palettes
```

### Attributes

- `interval` - Status update interval in seconds (default: 30)
- `timeout` - HTTP timeout in seconds (default: 5)  
- `disable` - Disable device (0/1, default: 0)
- `websocket` - Enable WebSocket connection for real-time updates (0/1, default: 0)
- `sections` - Comma-separated list of sections to show (optional)
- `webCmd` - Generated automatically based on field types for UI controls
- Widget definitions are integrated directly into commands (following FHEM best practices)

### Example FHEM configuration

```perl
# Define the LED controller
define livingroom_led LEDController 192.168.1.100:80

# Enable WebSocket for real-time updates
attr livingroom_led websocket 1
attr livingroom_led interval 15

# Automation examples
define evening_mood at *19:00:00 { \
  fhem("set livingroom_led on"); \
  fhem("set livingroom_led brightness 80"); \
  fhem("set livingroom_led solid_color FF8000"); \
}

define night_light at *23:00:00 { \
  fhem("set livingroom_led brightness 20"); \
  fhem("set livingroom_led solid_color 0000FF"); \
}

define party_mode notify mybutton:on { \
  fhem("set livingroom_led auto_play 3"); \
  fhem("set livingroom_led brightness 255"); \
}
```

## API Integration

This module uses the **actual LED_Stripe_Dynamic_web_conf API**, not a fake REST interface:

### Real API Endpoints

- **`/all`** - Get field structure (JSON array of field definitions)
- **`/allvalues`** - Get current values (JSON array of name/value pairs)  
- **`/set?field=value`** - Set field values with query parameters
- **`/status`** - Get detailed status information
- **`/getmodes`** - Get available effects/modes
- **`/getpals`** - Get available color palettes
- **`/ws`** - WebSocket endpoint for real-time updates

### Field Structure Discovery

The module discovers the device structure from `/all` endpoint which returns fields like:

```json
[
  {
    "name": "power",
    "label": "On/Off", 
    "type": 1,
    "min": 0,
    "max": 1
  },
  {
    "name": "brightness",
    "label": "Brightness",
    "type": 0,
    "min": 0,
    "max": 255
  },
  {
    "name": "effect",
    "label": "Effect",
    "type": 2,
    "min": 0,
    "max": 45,
    "options": ["Static", "Ease", "Rainbow", ...]
  }
]
```

### Command Translation

Commands are translated to proper API calls:

- `set myLED brightness 128` → `GET /set?brightness=128`
- `set myLED solid_color FF0000` → `GET /set?solidColor=solidColor&r=255&g=0&b=0`
- `set myLED effect 5` → `GET /set?effect=5`

## FHEM Control Elements

The module automatically generates appropriate FHEM control elements based on the field types discovered from the device:

### webCmd Generation

The `webCmd` attribute is automatically built with controls matching each field type:

- **NumberFieldType** → `field:slider,min,1,max` (e.g., `brightness:slider,0,1,255`)
- **BooleanFieldType** → `field:on,off` (e.g., `auto_play:on,off`) 
- **SelectFieldType** → `field:0,Option1,1,Option2,...` (e.g., `effect:0,Static,1,Rainbow,2,Fire`)
- **ColorFieldType** → `field:colorpicker,RGB` (e.g., `solid_color:colorpicker,RGB`)
- **Power Field** → Special case: generates separate `on` and `off` commands

### Widget Integration

Widget definitions are integrated directly into commands following FHEM best practices:

- **NumberFieldType** → `field:slider,min,step,max` for smooth slider controls (e.g., `brightness:slider,0,1,255`)
- **BooleanFieldType** → `field:uzsuToggle,off,on` for toggle switches (e.g., `auto_play:uzsuToggle,off,on`)
- **SelectFieldType** → `field:selectnumbers,Option1,Option2,...` for dropdown lists (options with spaces are quoted)
- **ColorFieldType** → `field:colorpicker` for color selection (e.g., `solid_color:colorpicker`)
- **Power Field** → Special case: generates simple `on` and `off` commands without widgets

This approach ensures that widgets are properly recognized by fhemWeb and eliminates the need for users to manually configure widget overrides.

### Status Readings

- **power** reading automatically updates the FHEM `state` to "on" or "off"
- **websocket_connection** reading shows WebSocket status: "connected", "disconnected", "connecting", or "failed"

## WebSocket Support

WebSocket support provides real-time updates from the LED controller:

- Enable with `attr myLED websocket 1`
- Receives live updates when values change on the device
- Updates FHEM readings automatically without polling
- Handles JSON messages in format: `{"name": "field_name", "value": field_value}`

## Troubleshooting

1. **No commands available**: Use `set myLED refresh` to reload field structure
2. **Connection errors**: Check network connectivity and device IP/port
3. **Invalid commands**: Use `set myLED ?` to see available commands for your device
4. **WebSocket issues**: Check FHEM logs and ensure device supports WebSocket on `/ws`

## Contributing

This module is part of the led-controller-fhem project. Please submit issues and pull requests to the GitHub repository.
