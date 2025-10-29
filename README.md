# kdbx-packages

Repository for Data Intellect KDB-X packages.

See [discussions](https://github.com/DataIntellectTech/kdbx-packages/discussions)
tab for proposed packages and
[issues](https://github.com/DataIntellectTech/kdbx-packages/issues) tab for
packages in active development.

Each package consists of: 

* code
* documentation
* tests

Tests are run using k4unit (which is also a module). To run the tests for a package: 

```q
q)k4unit:use`k4unit
q)k4unit.packagetest`package_to_test
```

## Contributing

We enthusiastically welcome contributions from outside of Data Intellect. If you
would like to contribute code, please do so via Pull Request. We also welcome
comments on open Pull Requests reviewing code.

Please create a separate directory for each package and place code,
documentation and unit tests within. All packages must have documentation and
unit tests to be accepted.

Style should conform to the [style guide](style.md) in this repository,
and implement the outlined [consistency requirements](consistency.md). 
