## TL;DR
A useful adapter restricts real capabilities, records dependency assumptions, and gives application code a vocabulary it owns.

## How it works
These original sketches distinguish caller tests using doubles from real dependency compatibility tests. Surrounding API names are illustrative; select the actual dependency version and contract before implementing an adapter.

## B01 — Type safety and capability safety solve different problems

A raw sensor map requires casts. A typed map removes casts, but still lets recipients clear or replace entries. A narrow lookup can own that capability boundary.

```python
class SensorCatalog:
    def __init__(self, sensors_by_id):
        self._sensors = dict(sensors_by_id)

    def find(self, sensor_id):
        return self._sensors.get(sensor_id)
```

The catalog exposes lookup without exposing clear/remove. Copying the map here also establishes snapshot membership; that is an explicit contract choice. A typed read-only mapping may be simpler if no domain operation or policy is needed.

**Check:** intended lookups and missing-ID behavior work; callers cannot mutate membership through the public API. This does not make returned sensor objects immutable. Do not wrap every map or invent an unstable-library concern for a stable standard interface.

## B02 — Learn logger configuration independently, then retain the useful contract

A console logger may require both an output destination and a layout. Guessing its defaults inside production code mixes integration errors with application errors.

```python
def test_console_adapter_emits_one_formatted_message(capsys):
    logger = application_logging.console_logger()

    logger.info("probe")

    output = capsys.readouterr()
    assert output.out == "INFO probe\n"
    assert output.err == ""
```

This is a test of the application's adapter, not a claim about a particular library's defaults. During initial exploration, isolate three questions: what an unconfigured logger does, whether an explicit layout makes a console destination usable, and whether an omitted destination defaults as documented. Change one configuration element per experiment.

The adapter encodes the chosen behavior. Its compatibility test then runs against supported dependency versions and catches changed defaults or duplicate emission.

**Check:** assertions observe real emitted output, initialization does not accumulate handlers, and each test restores process-global logging state. A fake logger cannot prove formatting or provider configuration. Keep temporary vendor experiments separate from durable project tests according to repository conventions.

## B03 — Define the transmitter operation you need before the provider exists

```python
class RadioController:
    def __init__(self, transmitter):
        self._transmitter = transmitter

    def broadcast(self, frequency_hz, samples):
        self._transmitter.transmit(frequency_hz, samples)


class DeviceTransmitter:
    def __init__(self, device):
        self._device = device

    def transmit(self, frequency_hz, samples):
        self._device.tune_hz(frequency_hz)
        self._device.emit(samples)
```

The controller can be developed against its frequency/stream contract. A recording fake checks the command it issues; the provider adapter later owns unit conversion, device calls, and lifecycle rules. The shown device contract assumes tuning precedes emission and no separate keyed session is required.

**Check:** a caller test verifies the selected frequency and stream reach `transmit` unchanged. Separate adapter tests verify the real device's units, ordering, failure behavior, and resource release. If the provider needs key/unkey or cancellation, implement and test those explicitly; the fake cannot establish them. Avoid buffering an entire stream merely to make assertions convenient.
