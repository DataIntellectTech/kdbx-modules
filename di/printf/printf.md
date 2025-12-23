
# Printf module reference

The DI printf module replicates the core functionality provided by KX's printf module. 

The kdb-x printf module replicates a subset of the C99 printf standard to format strings.

For the purpose of documenting, the coded examples provided here assume the printf module has been loaded into the root namespace:

```q
([printf]):use`di.printf
```

But remember, under the kdb-x module framework this can be loaded into a project under any name desired.

## Specification

The C standard library printf specification can be found [here](https://man7.org/linux/man-pages/man3/printf.3.html). Rather than rehashing the specification, this documentation will note deviations in behaviour from the specification.

For reference, the overall syntax from the C standard spec is:

```
%[argument$][flags][width][.precision][length modifier]conversion
```

This module deviates from this in the following ways:

- The C99 specification which this module mirrors does not include the UNIX Specification of repeated references to the same argument. So the `[argument$]` component of the conversion specification is dropped
- Due to the differing type systems between C and q, the length modifier field doesn't translate well to q. As such, this component of the conversion specification is also dropped

Hence, the specification for this module is as follows:

```
%[flags][width][.precision]conversion
```

### Flags

Of the C99 standard flags available, only the "alternate form" is excluded.

|    Text   |Description|
|:---------:|:-----------:|
|     -     | Left-align the output of this placeholder; default is to right-align the output|
|     +     | Prepends a plus sign for a positive value; by default a positive value does not have a prefix|
|   (space) | Prepends a space character for a positive value; ignored if the + flag exists; by default a positive value does not have a prefix|
|     0     | When the 'width' option is specified, prepends zeros instead of spaces for numeric types; for example, printf("%4X",3) produces "   3", while printf("%04X",3); produces "0003"|

### Width

The width field operates the same as the C99 standard, with the exception of the `*` form, where one argument is used to specify the width of the variable being replaced. If width needs to be variable it's recommended to handle this in the user provided string. E.g.

```q
q)vwidth:8;
q)printf ("Variadic width %",string[vwidth],".2f"; 1.61803)
"Variadic width     1.62"
```

### Precision

The precision field operates the same as the C99 standard printf.

### Type Field

Due to the differing type systems between C and q, there are a number of excluded fields, and one added field:

Differences are:
- `i` is removed, as the only difference with `d` is use in junction with `scanf`
- `u` is removed, as unsigned integers don't exist in q
- `F` is removed, as the only difference with `f` is capitals on nulls or infinities. q's printf will just print 0w, 0n
- `p` is removed, as pointers aren't considered
- `n` is removed
- `a` and `A` are removed
- `r` is added for representations of types that don't exist (`p`, `n` ...)

The amended table is:

| Text |Description|
|:----:|:-----------:|
|   %  | Output a literal % character; does not accept flags, width, precision or length fields|
| d | long |
| f | float |
| x, X | hexadecimal representation |
|   o  | octal representation |
|   s  | string or symbol |
|   r  | string representations of q types that don't exist in C|

Some notes:

- The string flag is permissive, it's a no-op conversion on strings, it runs `string` on symbols, and calls .Q.s1 if it's a different type. 
- For long and float these are cast with `"j"` and `"f"` respectively, if a string is provided as the argument for the conversion specification in junction with a `%d` or `%j` type field the cast is attempted with `"J"` and `"F"` respectively.
- `%r` simply interprets the argument with .Q.s1, this is useful for q types that don't have a direct C type mapping (timestamps, dictionaries etc.)
- Hexadecimal and octal representation uses the approach noted in [casting](https://code.kx.com/phrases/cast/)
- For floats, IEEE754 precision format is utilised via [`-27!`](https://code.kx.com/q/basics/internal/#-27xy-ieee754-precision-format)

## Printf

```q
printf[message]
```

Where `message` is either
- A string
- A general list, where
    - The first item is a string with conversion specifiers
    - The following items are variables to be formatted as specified by the conversion specifiers

