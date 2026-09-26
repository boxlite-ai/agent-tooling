## TL;DR
A maintainable test exposes one scenario, the real operation, and an automatically checked outcome without unnecessary setup machinery.

## How it works
These original test sketches use illustrative application fixtures. Helpers must call the production API; they must not manufacture the value later asserted. Retain independent setup, explicit environmental assumptions, and failure messages that reveal the broken contract.

## T01 — Replace a manually observed timer with controlled time

Before, a person types characters and judges whether they reappear after a delay. After, the scheduler receives a controllable clock and a command whose execution is observable.

```python
def test_command_runs_when_due(clock, scheduler):
    calls = []
    scheduler.schedule(lambda: calls.append("ran"), delay_ms=50)

    clock.advance_ms(49)
    scheduler.run_due()
    assert calls == []

    clock.advance_ms(1)
    scheduler.run_due()
    assert calls == ["ran"]

    scheduler.run_due()
    assert calls == ["ran"]
```

The test controls the boundary rather than sleeping and hoping the operating system schedules work. The scheduler, not the test, invokes the callback. Here the explicit `run_due` contract makes no claim about threads.

**Check:** not-before, due-time, and once-only behavior; add ordering, cancellation, and shutdown cases when part of the contract. A real asynchronous scheduler also needs integration evidence for wakeups and completion; fake time alone does not prove those properties.

## T02 — Give responder tests a small domain vocabulary

Repeated path parsing and response casts can bury the scenario. Helpers for pages and links expose the relevant setup without replacing the responder under test.

```python
def test_hierarchy_lists_nested_pages(site, client):
    site.add_pages("Guide", "Guide.Install", "Reference")

    response = client.get_hierarchy("root")

    assert response.media_type == "text/xml"
    assert page_names(response.body) == {"Guide", "Install", "Reference"}


def test_hierarchy_excludes_symbolic_links(site, client):
    site.add_pages("Guide", "Reference")
    site.add_symbolic_link("Guide", "Shortcut", target="Reference")

    response = client.get_hierarchy("root")

    assert "Shortcut" not in page_names(response.body)
    assert page_names(response.body) == {"Guide", "Reference"}


def test_page_content_is_serialized(site, client):
    site.add_page("Guide", content="installation notes")

    response = client.get_page_data("Guide")

    assert response.media_type == "text/xml"
    assert page_content(response.body) == "installation notes"
```

The three scenarios remain distinct: hierarchy content, symbolic-link omission, and page data. Each test builds its own fixture, invokes the real responder through `client`, then checks its output. `page_names` and `page_content` parse that output; they do not echo input fixtures.

**Check:** deleting a real page from the response or exposing a symbolic link makes the corresponding test fail. Keep decisive data visible; a large inherited fixture or magical helper can make tests harder to maintain than a few repeated setup lines.

## T03 — Describe thermostat outcomes without a decoding puzzle

Before, the reader alternates between several field names and positive/negative assertions. A compact state string reduces repetition but requires memorizing letter positions. A modern adaptation uses a named state value.

```python
@pytest.mark.parametrize("temperature, expected", [
    (TOO_COLD, Outputs(heater=True, blower=True, cooler=False,
                       high_alarm=False, low_alarm=False)),
    (TOO_HOT, Outputs(heater=False, blower=True, cooler=True,
                      high_alarm=False, low_alarm=False)),
    (EXTREME_COLD, Outputs(heater=True, blower=True, cooler=False,
                           high_alarm=False, low_alarm=True)),
    (EXTREME_HOT, Outputs(heater=False, blower=True, cooler=True,
                          high_alarm=True, low_alarm=False)),
])
def test_temperature_controls_outputs(temperature, expected, controller, hardware):
    hardware.set_temperature(temperature)

    controller.tick()

    assert hardware.outputs() == expected
```

Each row describes one scenario with an independent fixture. The named structure improves failed-assertion diffs and removes mental mapping. Allocating a small expected value is usually acceptable in a test even if the production controller has strict memory limits.

**Check:** fixture constants lie in the intended regions; test exact thresholds and neighboring values separately. Do not compute expected outputs using the controller's own decision code. Keep tests fast enough to run frequently; “test-only” is not permission for unbounded work.

## T04 — One contract may require several assertions

```python
def test_hierarchy_response_contract(site, client):
    site.add_page("Guide")

    response = client.get_hierarchy("root")

    assert response.media_type == "text/xml"
    assert page_names(response.body) == {"Guide"}
```

Splitting the two assertions merely to satisfy an assertion quota duplicates setup or encourages elaborate base classes. Both observations describe the same response. Separate tests when scenarios or reasons for failure differ, not whenever an assertion count exceeds one.

**Check:** a wrong media type and wrong body each produce a useful failure. If early assertion failure conceals important independent diagnostics, consider a suitable aggregate assertion rather than compulsory fixture inheritance.

## T05 — Separate month-addition rules and discover missing cases

```python
@pytest.mark.parametrize("start, months, expected", [
    (date(2025, 5, 31), 1, date(2025, 6, 30)),
    (date(2025, 5, 31), 2, date(2025, 7, 31)),
    (date(2025, 6, 30), 1, date(2025, 7, 30)),
    (date(2025, 2, 28), 1, date(2025, 3, 28)),
])
def test_month_addition_clamps_only_when_needed(start, months, expected):
    assert add_months(start, months) == expected
```

The table replaces a long sequence sharing intermediate dates. It reveals a domain rule: preserve the original day unless the target month is too short. This contract does not automatically preserve “last day of month.” It also makes the previously missing February-to-March case obvious.

**Check:** two additions of one month to May 31 yield July 30, whereas one addition of two months yields July 31 under this contract. Confirm the project's intended calendar semantics before asserting that behavior; other domains deliberately preserve end-of-month status. Add leap-year and negative-offset cases when relevant.
