# kdbx-modules

Repository for Data Intellect KDB-X modules.

See [discussions](https://github.com/DataIntellectTech/kdbx-modules/discussions)
tab for proposed modules and
[issues](https://github.com/DataIntellectTech/kdbx-modules/issues) tab for
modules in active development.

## Usage

In order to use the modules from this repo:

1. Download the modules code [here](https://github.com/DataIntellectTech/kdbx-modules/archive/refs/heads/main.zip)
  ```bash
  $ wget https://github.com/DataIntellectTech/kdbx-modules/archive/refs/heads/main.zip
  ```
2. Unzip downloaded code
  ```bash
  $ unzip main.zip
  ```
3. Set `QPATH` environment variable to point to download location (preserving any existing value)
  ```bash
  $ export QPATH=${QPATH}:~/kdbx-modules-main/
  ```
4. Run KDB-X and use `use` keyword to import modules - all modules begin with `di.` e.g. `di.usage`
  ```bash
  $ q
  KDB-X 0.1.2 2025.10.18 Copyright (C) 1993-2025 Kx Systems
  l64/ 64()core 385394MB jmcmurray homer.aquaq.co.uk 127.0.1.1 EXPIRE 2026.03.26 dataintellect.com KXMS #95155

  q)usage:use`di.usage
  ```

## Module layout

Each module consists of: 

* code
* documentation
* tests

Tests are run using k4unit (which is also a module). To run the tests for a module: 

```q
q)k4unit:use`k4unit
q)k4unit.moduletest`module_to_test
```

## Contributing

We enthusiastically welcome contributions from outside of Data Intellect. If you
would like to contribute code, please do so via Pull Request. We also welcome
comments on open Pull Requests reviewing code.

Please create a separate directory for each module and place code,
documentation and unit tests within. All modules must have documentation and
unit tests to be accepted.

Style should conform to the [style guide](style.md) in this repository,
and implement the outlined [consistency requirements](consistency.md). 
