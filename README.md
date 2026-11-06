# dafny-in-dotnet

A minimal example of adding [Dafny](https://github.com/dafny-lang/dafny) code to a C# project. The build checks the Dafny proofs, translates the Dafny to C# and compiles it into the app. A failing proof fails the build.

It's a small model of adding proof-checked code to a large existing C# codebase. The entry point stays ordinary C#, and one piece of logic moves into Dafny.

## The code

### `greeting.dfy` (Dafny)

```dafny
module Greetings {
  class Greeter {
    static method Greeting() returns (greeting: string)
      ensures greeting == "Hello"
    {
      return "Hello";
    }
  }
}
```

- `ensures greeting == "Hello"` is a **postcondition**: Dafny proves that every path through the method returns `"Hello"`. Specifications like this are only used for proving, so they cost nothing when the program runs.
- The `module` becomes a C# **namespace** and the `class` becomes a C# **class**.

### `Program.cs` (C#)

```csharp
var greeting = Greetings.Greeter.Greeting().ToVerbatimString(false);
Console.WriteLine($"{greeting}, World!");
```

The entry point is ordinary C# top-level statements. A Dafny `string` is a sequence of Unicode characters, so the generated method returns `Dafny.ISequence<Dafny.Rune>`, not `System.String`. `ToVerbatimString(false)` turns it into a .NET string.

### The generated C#

At build time, Dafny generates this from `greeting.dfy` (shortened):

```csharp
namespace Greetings {
  public partial class Greeter {
    public static Dafny.ISequence<Dafny.Rune> Greeting()
    {
      Dafny.ISequence<Dafny.Rune> greeting = Dafny.Sequence<Dafny.Rune>.Empty;
      greeting = Dafny.Sequence<Dafny.Rune>.UnicodeFromString("Hello");
      return greeting;
      return greeting;
    }
  }
}
```

It's written to `obj/<Configuration>/<TargetFramework>/Dafny/Dafny.g.cs` and isn't committed. The second `return` causes a harmless CS0162 "unreachable code" warning.

## How `main.csproj` links them together

Apart from the usual console app settings, the project file does four things.

**1. References the Dafny runtime library**

```xml
<PackageReference Include="DafnyRuntime" Version="4.11.0" />
```

The generated C# uses types such as `Dafny.ISequence<T>` and `Dafny.Rune` from the [`DafnyRuntime`](https://www.nuget.org/packages/DafnyRuntime/4.11.0) NuGet package. Its version **must match** the `dafny` tool that generates the code, because the generated code is written for that runtime version.

**2. Collects the Dafny source files**

```xml
<DafnySource Include="**/*.dfy" Exclude="$(BaseOutputPath)**;$(BaseIntermediateOutputPath)**" />
```

This makes an item list of every `.dfy` file in the project, the same way the SDK picks up every `.cs` file. `bin/` and `obj/` are excluded. The `DafnyExe` property defaults to `dafny` on the `PATH`, and you can override it with `dotnet build -p:DafnyExe=/path/to/dafny`.

**3. Works out where the generated file goes (`SetDafnyPaths` target)**

```xml
<DafnyGeneratedFile>$(IntermediateOutputPath)Dafny/Dafny.g.cs</DafnyGeneratedFile>
```

`IntermediateOutputPath` (`obj/Debug/net10.0/`) is only defined once the SDK's targets have loaded, which is after the body of the project file is evaluated. Setting this property inside a target delays it until build time, when the value is known. Setting it at the top level would put the generated file in `./Dafny/` instead.

**4. Checks the proofs and translates the Dafny to C# before compiling (`TranslateDafny` target)**

```xml
<Target Name="TranslateDafny"
        BeforeTargets="CoreCompile"
        DependsOnTargets="SetDafnyPaths"
        Condition="'@(DafnySource)' != ''"
        Inputs="@(DafnySource);$(MSBuildProjectFullPath)"
        Outputs="$(DafnyGeneratedFile)">
  <Exec Command="&quot;$(DafnyExe)&quot; translate cs @(DafnySource->'&quot;%(FullPath)&quot;', ' ') --output &quot;$(DafnyGeneratedFile)&quot;" />
  <ItemGroup>
    <Compile Include="$(DafnyGeneratedFile)" />
    <FileWrites Include="$(DafnyGeneratedFile)" />
  </ItemGroup>
</Target>
```

- **`BeforeTargets="CoreCompile"`** runs this target just before the C# compiler runs.
- **The `Exec` task** runs `dafny translate cs` on all the `.dfy` files. `translate` checks the proofs (using the Z3 solver) before it generates any code. If a proof fails, `dafny` exits with an error, `Exec` fails and the build stops. You get an error like `greeting.dfy(4,2): error : a postcondition could not be proved on this return path`.
- **`Inputs` / `Outputs`** make the target incremental. MSBuild skips the translation, including the slow proof checking, when the generated file is newer than every `.dfy` file and the project file. Because the `ItemGroup` still runs when the target is skipped, the generated file is still compiled.
- **`<Compile Include=...>`** adds the generated file to the files the C# compiler compiles. This works because it happens before `CoreCompile`.
- **`<FileWrites Include=...>`** records the generated file as a build output, so `dotnet clean` deletes it.
- **The `Condition`** makes the target do nothing if the project has no `.dfy` files.

Paths use `/`, which works on both Windows and Linux. A `\` in the generated file's path breaks the build on Linux.

## Building

### Prerequisites

| Tool | Version | Why |
| --- | --- | --- |
| .NET SDK | 10.0 | Builds the C# |
| Dafny | 4.11.0 | Checks the proofs and translates `.dfy` to C#. Must match `DafnyRuntime` in `main.csproj` |
| Z3 | 4.12.1 | The solver Dafny uses to check proofs |

```bash
dotnet tool install --global dafny --version 4.11.0
```

Installing Dafny as a .NET tool **doesn't include Z3**. Download Z3 4.12.1 for your platform from the [Z3 releases page](https://github.com/Z3Prover/z3/releases/tag/z3-4.12.1) and do one of the following:

- Put the folder containing `z3` on your `PATH`. The [Dafny installation guide](https://dafny.org/latest/Installation#nuget-binary) recommends this.
- Copy `z3.exe` to `z3/bin/z3-4.12.1.exe` next to the Dafny tool's DLLs, for example `~/.dotnet/tools/.store/dafny/4.11.0/dafny/4.11.0/tools/net8.0/any/z3/bin/z3-4.12.1.exe`. Dafny's "Z3 is not found" error lists this as one of the places it looks. You'll need to do this again if you reinstall Dafny.

### Build and run

```bash
dotnet build
dotnet run    # Hello, World!
```

### CI

[`.github/workflows/build.yml`](.github/workflows/build.yml) installs the tools above on Ubuntu, builds the project (which checks the proofs) and checks that the app prints `Hello, World!`. The tool versions are pinned at the top of the workflow. A workflow step fails if the `DafnyRuntime` version in `main.csproj` doesn't match the Dafny tool version.

## Further reading

- [Dafny: C# integration](https://dafny.org/latest/DafnyRef/integration-cs/IntegrationCS): calling [Dafny from C#](https://dafny.org/latest/DafnyRef/integration-cs/IntegrationCS#calling-dafny-from-c) and C# from Dafny, and [how Dafny types map to C# types](https://dafny.org/latest/DafnyRef/integration-cs/IntegrationCS#types). This page also suggests adding `{:extern "Name"}` to a module to choose its C# namespace name explicitly. We rely on the default, where the namespace takes the module's name.
- [Dafny reference: `dafny translate`](https://dafny.org/latest/DafnyRef/DafnyRef#sec-dafny-translate). Translation always resolves the code and also checks the proofs unless `--no-verify` is given.
- [Dafny reference: modules](https://dafny.org/latest/DafnyRef/DafnyRef#sec-module-definition), [classes](https://dafny.org/latest/DafnyRef/DafnyRef#sec-class-types), [strings](https://dafny.org/latest/DafnyRef/DafnyRef#sec-strings) and [newtypes](https://dafny.org/latest/DafnyRef/DafnyRef#sec-newtypes). Newtypes let you use native integer types instead of `BigInteger` in generated code.
- [Dafny installation](https://dafny.org/latest/Installation#nuget-binary): the .NET tool install and Z3 requirements.
- MSBuild: [target build order (`BeforeTargets`, `DependsOnTargets`)](https://learn.microsoft.com/en-us/visualstudio/msbuild/target-build-order), [incremental builds (`Inputs`/`Outputs`)](https://learn.microsoft.com/en-us/visualstudio/msbuild/incremental-builds), the [`Exec` task](https://learn.microsoft.com/en-us/visualstudio/msbuild/exec-task) and [cleaning a build](https://learn.microsoft.com/en-us/visualstudio/msbuild/how-to-clean-a-build).

The Dafny docs mainly describe Dafny driving the build (`dafny run --target:cs ... --input Other.cs`). We haven't found official docs for the reverse, where an existing MSBuild project runs Dafny as a build step, which is what this repo does. [dafny-lang/dafny.msbuild](https://github.com/dafny-lang/dafny.msbuild) provides MSBuild tasks for projects containing Dafny source, but it hasn't been updated since 2022.
