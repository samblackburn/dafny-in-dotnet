module Greetings {
  class Greeter {
    static method Greeting() returns (greeting: string)
      ensures greeting == "Hello"
    {
      return "Hello";
    }
  }
}
