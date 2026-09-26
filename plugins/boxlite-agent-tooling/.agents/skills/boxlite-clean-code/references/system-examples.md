## TL;DR
Separate assembly, domain behavior, and infrastructure policy while making their composition and runtime effects visible.

## How it works
These original adaptations retain the service, order, and bank scenarios while replacing historical framework mechanics with illustrative APIs. Code sketches are not recommendations for a particular container, ORM, or aspect framework. Verify both isolated behavior and actual wiring.

## S01 — Move service selection to assembly without losing lifetime semantics

```python
# Before: a normal operation also selects and constructs infrastructure.
def lookup_customer(self, customer_id):
    if self._directory is None:
        self._directory = RemoteDirectory(self._settings)
    return self._directory.lookup(customer_id)


# After: assembly supplies the selected dependency.
def build_application(settings):
    directory = RemoteDirectory(settings.directory)
    return CustomerApplication(directory)
```

The application now uses a dependency instead of knowing the global default and how to construct it. Construction and operation need different knowledge, just as building a hotel and running it do.

**Check:** selected configuration, ownership, close behavior, and reuse lifetime remain correct. Eager construction moves cost and failure earlier; preserve deliberate laziness through an explicitly owned provider when needed. Constructing an ordinary local value is not a violation of this separation.

## S02 — Let an order choose when a line item is created

```python
class Order:
    def __init__(self, make_line):
        self._make_line = make_line
        self._lines = []

    def add_product(self, product_id, quantity):
        line = self._make_line(product_id, quantity)
        self._lines.append(line)
```

Before, order logic also knows pricing/configuration details needed to construct the concrete item. After, an injected factory owns those details, while the order still controls creation timing and supplies product/quantity.

**Check:** rejected construction leaves the order unchanged, each accepted request creates one line, and quantity/product arguments survive. If a line is simply a stable value with an obvious constructor, introducing a factory may add no value. Do not hide side effects such as stock reservation behind an innocuous factory name.

## S03 — Service lookup is different from receiving a dependency

```python
# Before: application logic can resolve arbitrary named services.
directory = services.lookup("customer-directory")
customer = directory.lookup(customer_id)

# After: assembly performs any lookup; the operation receives what it needs.
customer = self._directory.lookup(customer_id)
```

A service locator controls which implementation is returned, but the consumer still resolves the dependency and knows its name. Constructor or function injection makes that requirement explicit. Container access can remain in the assembly module.

**Check:** missing dependencies fail at the intended stage, the application cannot accidentally resolve a different service, and tests supply only actual requirements. A lazy provider needs its own initialization, caching, failure, and thread-safety contract; injection does not supply those automatically.

## S04 — Keep bank behavior usable without a container lifecycle

```python
class Bank:
    def __init__(self, bank_id):
        self.bank_id = bank_id
        self._accounts = []

    def attach_account(self, account):
        if account.bank_id != self.bank_id:
            raise ValueError("account belongs to a different bank")
        self._accounts.append(account)
```

Before, a bank entity must inherit framework types, implement lifecycle callbacks, perform service lookups, and copy transport records merely to attach an account. After, the domain operation can be tested directly; persistence and framework integration live at their own boundary.

This adaptation makes the bank/account invariant explicit. A real application must preserve its existing association and duplicate-account rules rather than silently adopting this sketch's choices.

**Check:** ordinary domain tests run without a server; persistence integration still enforces transaction, authorization, identity, and association rules. Removing container coupling without restoring its implicit guarantees is a behavioral regression.

## S05 — Compare manual interception, explicit composition, and systemic policy

A reflection-based proxy can dispatch on names:

```python
def intercept(method_name, arguments, domain, repository):
    if method_name == "list_accounts":
        return repository.list_accounts(domain.bank_id)
    return getattr(domain, method_name)(*arguments)
```

That keeps some storage logic outside the domain but adds string-based dispatch and another place where return values and exceptions can change. A narrow adapter or explicit decorator can be easier to follow:

```python
repository = AccountRepository(database)
service = AccountService(repository)
service = TransactionalAccounts(service, database)
service = AuthorizedAccounts(service, authorization)
```

Here authorization wraps the transaction boundary; changing that order can change behavior. A dependency-injection configuration can assemble the same graph instead of handwritten setup. A systemic aspect mechanism additionally selects many join points according to a rule; a single proxy around one object is not equivalent to that capability.

**Check:** intended calls cross the policy exactly once, excluded calls remain excluded, exception/cancellation propagation and transaction behavior survive, and authorization cannot be bypassed by another entry point. Verify self-calls and asynchronous calls according to the chosen runtime. Additional weaving tools or reflection machinery must earn their operational and debugging cost; no AOP framework is mandatory.

## S06 — Choose visible mapping metadata or an external map deliberately

```python
@dataclass
class BankRecord:
    bank_id: int
    address: Address


mapping = {
    BankRecord: {
        "table": "banks",
        "identity": "bank_id",
        "embedded": {"address": "address_"},
    }
}
```

This illustrative external mapping leaves the record independent of mapping annotations. An annotation-based alternative places equivalent table, identity, address, and account-association metadata beside the fields. Both can be less intrusive than container lifecycle inheritance; neither is automatically free of persistence coupling.

**Check:** round trips preserve identifiers and addresses; Bank/Account links remain consistent; cascade, loading, and transaction behavior match the intended contract. Choose according to actual mapping changes and framework conventions. Do not add a second model solely to remove stable harmless metadata, or assume annotations alone prove testability.

## S07 — Grow infrastructure when requirements justify it

```python
# Current requirement: fetch current account data.
accounts = AccountRepository(database)

# Later, if measured needs and allowed staleness justify a cache:
accounts = CachedAccounts(AccountRepository(database), cache_policy)
```

The evolution resembles widening a road when a town grows: building maximum capacity immediately is expensive, but no planning at all also creates problems. A separated boundary leaves room for a later decision without implementing the unused infrastructure now.

A standard or framework earns adoption through concrete interoperability, staffing, or capability requirements. “It is the standard” alone does not justify an invasive architecture.

**Check:** current behavior works with the simpler design. Adding caching is a contract change involving freshness, invalidation, errors, and consistency—not merely structural cleanup. Address irreversible constraints early and retain the project's required initial design work.

## S08 — Let application vocabulary express domain decisions

```python
# Before: caller knows a positional policy representation.
policy = {"kind": 2, "limit": 5000, "window": 24}

# After: an ordinary typed value can express the same domain meaning.
policy = TransferLimit(amount=Money("50.00", "USD"), window=hours(24))
```

This is an original illustration of domain vocabulary, not a new parser or framework requirement. Here the legacy schema specifies USD cents and hours. The amount and units are explicit, so a reviewer can discuss a transfer limit without decoding implementation tags. Similar clarity can come from named functions, constructors, or a small fluent API.

**Check:** the adapter preserves amount, currency, and time units and rejects ambiguous input. Domain experts should recognize the rule. Building a standalone language is justified only when its parser, tooling, and maintenance costs serve actual use.
