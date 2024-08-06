# RedisCodable

[![CI Status](https://img.shields.io/travis/dankinsoid/RedisCodable.svg?style=flat)](https://travis-ci.org/dankinsoid/RedisCodable)
[![Version](https://img.shields.io/cocoapods/v/RedisCodable.svg?style=flat)](https://cocoapods.org/pods/RedisCodable)
[![License](https://img.shields.io/cocoapods/l/RedisCodable.svg?style=flat)](https://cocoapods.org/pods/RedisCodable)
[![Platform](https://img.shields.io/cocoapods/p/RedisCodable.svg?style=flat)](https://cocoapods.org/pods/RedisCodable)


## Description
This repository provides

## Example

```swift

```
## Usage

 
## Installation

1. [Swift Package Manager](https://github.com/apple/swift-package-manager)

Create a `Package.swift` file.
```swift
// swift-tools-version:5.7
import PackageDescription

let package = Package(
  name: "SomeProject",
  dependencies: [
    .package(url: "https://github.com/dankinsoid/RedisCodable.git", from: "0.0.1")
  ],
  targets: [
    .target(name: "SomeProject", dependencies: ["RedisCodable"])
  ]
)
```
```ruby
$ swift build
```

2.  [CocoaPods](https://cocoapods.org)

Add the following line to your Podfile:
```ruby
pod 'RedisCodable'
```
and run `pod update` from the podfile directory first.

## Author

dankinsoid, voidilov@gmail.com

## License

RedisCodable is available under the MIT license. See the LICENSE file for more info.
