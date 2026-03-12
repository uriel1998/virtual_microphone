# virtual-mic

Scripts to create and manage virtual audio paths using `pactl` on Linux. 

Software with similar functionality exists for <a href="https://github.com/VirtualDrivers/Virtual-Audio-Driver">Windows</a> and <a href="https://apps.apple.com/us/app/dipper-audio-capture/id6450242673?mt=12">macOS</a>.

Each pipeline consists of:
- A virtual playback sink: `<label> playback sink`
- A virtual recording source: `<label> recording source` (from that sink's monitor)

The script creates device names with the `virt_` prefix.
Each pair is isolated from physical speakers/microphones because audio stays in a null sink + monitor source path.

![isolated_streams](https://github.com/uriel1998/virtual_microphone/blob/master/2026-03-12_11.54.36.png?raw=true)

## Requirements

- Linux with PipeWire/PulseAudio compatibility layer
- `pactl`

## Usage

```bash
./virtual-mic.sh -n <count> [-l <label>]...
./virtual-mic.sh status
./virtual-mic.sh off
./virtual-mic.sh -h
./virtual-mic.sh --help
```

## Commands

- `-n <count>`: Number of virtual pipeline pairs to create.
- `-l <label>`: Label for a pipeline. Can be repeated.
- `status`: Show all `virt_` sinks, sources, and matching modules.
- `off`: Remove all virtual devices/modules that reference `virt_`.
- `-h`, `--help`: Show help text.

## Label Behavior

Provided `-l` values are used first in order. If fewer labels are provided than `-n`, the script auto-generates names as `v1`, `v2`, `v3`, and so on.

Example:

```bash
./virtual-mic.sh -n 4 -l wombat -l wombat2
```

Creates labels in this order:
- `wombat`
- `wombat2`
- `v1`
- `v2`

## Examples

Create 2 pipelines with auto labels:

```bash
./virtual-mic.sh -n 2
```

Create 3 pipelines with one custom label:

```bash
./virtual-mic.sh -n 3 -l podcast
```

Check status:

```bash
./virtual-mic.sh status
```

Remove all created virtual devices:

```bash
./virtual-mic.sh off
```

## virtual-mic-mux.sh

`virtual-mic-mux.sh` combines audio streams (for example, mic + app audio) into a single virtual mic path.

![combined_streams](https://raw.githubusercontent.com/uriel1998/virtual_microphone/refs/heads/master/2026-03-12_11.54.56.png)

Show its built-in help:

```bash
./virtual-mic-mux.sh -h
```

Current usage from the script:

```bash
./virtual-mic-mux.sh on
./virtual-mic-mux.sh off
./virtual-mic-mux.sh status
```

Command summary:
- `on`: Create and enable the muxed virtual mic path.
- `off`: Tear it down and restore previous defaults.
- `status`: Show current mux status.
