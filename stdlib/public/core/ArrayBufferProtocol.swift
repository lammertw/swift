//===--- ArrayBufferType.swift --------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2016 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

/// The underlying buffer for an ArrayType conforms to
/// `_ArrayBufferProtocol`.  This buffer does not provide value semantics.
public protocol _ArrayBufferProtocol : MutableCollection {
  /// The type of elements stored in the buffer.
  associatedtype Element

  /// Create an empty buffer.
  init()

  /// Adopt the entire buffer, presenting it at the provided `startIndex`.
  init(_ buffer: _ContiguousArrayBuffer<Element>, shiftedToStartIndex: Int)

  /// Copy the elements in `bounds` from this buffer into uninitialized
  /// memory starting at `target`.  Return a pointer past-the-end of the
  /// just-initialized memory.
  func _copyContents(
    subRange bounds: Range<Int>,
    initializing target: UnsafeMutablePointer<Element>
  ) -> UnsafeMutablePointer<Element>

  /// Get or set the index'th element.
  subscript(index: Int) -> Element { get nonmutating set }

  /// If this buffer is backed by a uniquely-referenced mutable
  /// `_ContiguousArrayBuffer` that can be grown in-place to allow the `self`
  /// buffer store `minimumCapacity` elements, returns that buffer.
  /// Otherwise, returns `nil`.
  ///
  /// - Note: The result's firstElementAddress may not match ours, if we are a
  ///   _SliceBuffer.
  ///
  /// - Note: This function must remain mutating; otherwise the buffer
  ///   may acquire spurious extra references, which will cause
  ///   unnecessary reallocation.
  @warn_unused_result
  mutating func requestUniqueMutableBackingBuffer(
    minimumCapacity minimumCapacity: Int
  ) -> _ContiguousArrayBuffer<Element>?

  /// Returns `true` iff this buffer is backed by a uniquely-referenced mutable
  /// _ContiguousArrayBuffer.
  ///
  /// - Note: This function must remain mutating; otherwise the buffer
  ///   may acquire spurious extra references, which will cause
  ///   unnecessary reallocation.
  @warn_unused_result
  mutating func isMutableAndUniquelyReferenced() -> Bool

  /// If this buffer is backed by a `_ContiguousArrayBuffer`
  /// containing the same number of elements as `self`, return it.
  /// Otherwise, return `nil`.
  @warn_unused_result
  func requestNativeBuffer() -> _ContiguousArrayBuffer<Element>?

  /// Replace the given `subRange` with the first `newCount` elements of
  /// the given collection.
  ///
  /// - Precondition: This buffer is backed by a uniquely-referenced
  /// `_ContiguousArrayBuffer`.
  mutating func replace<C : Collection where C.Iterator.Element == Element>(
    subRange subRange: Range<Int>,
    with newCount: Int,
    elementsOf newValues: C
  )

  /// Returns a `_SliceBuffer` containing the elements in `bounds`.
  subscript(bounds: Range<Int>) -> _SliceBuffer<Element> { get }

  /// Call `body(p)`, where `p` is an `UnsafeBufferPointer` over the
  /// underlying contiguous storage.  If no such storage exists, it is
  /// created on-demand.
  func withUnsafeBufferPointer<R>(
    @noescape body: (UnsafeBufferPointer<Element>) throws -> R
  ) rethrows -> R

  /// Call `body(p)`, where `p` is an `UnsafeMutableBufferPointer`
  /// over the underlying contiguous storage.
  ///
  /// - Precondition: Such contiguous storage exists or the buffer is empty.
  mutating func withUnsafeMutableBufferPointer<R>(
    @noescape body: (UnsafeMutableBufferPointer<Element>) throws -> R
  ) rethrows -> R

  /// The number of elements the buffer stores.
  var count: Int { get set }

  /// The number of elements the buffer can store without reallocation.
  var capacity: Int { get }

  /// An object that keeps the elements stored in this buffer alive.
  var owner: AnyObject { get }

  /// If the elements are stored contiguously, a pointer to the first
  /// element. Otherwise, `nil`.
  var firstElementAddress: UnsafeMutablePointer<Element> { get }

  /// Returns a base address to which you can add an index `i` to get the
  /// address of the corresponding element at `i`.
  var subscriptBaseAddress: UnsafeMutablePointer<Element> { get }

  /// Like `subscriptBaseAddress`, but can assume that `self` is a mutable,
  /// uniquely referenced native representation.
  /// - Precondition: `_isNative` is `true`.
  var _unconditionalMutableSubscriptBaseAddress:
    UnsafeMutablePointer<Element> { get }

  /// A value that identifies the storage used by the buffer.  Two
  /// buffers address the same elements when they have the same
  /// identity and count.
  var identity: UnsafePointer<Void> { get }

  var startIndex: Int { get }
}

extension _ArrayBufferProtocol {
  public var subscriptBaseAddress: UnsafeMutablePointer<Element> {
    return firstElementAddress
  }

  public var _unconditionalMutableSubscriptBaseAddress:
    UnsafeMutablePointer<Element> {
    return subscriptBaseAddress
  }

  public mutating func replace<
    C : Collection where C.Iterator.Element == Element
  >(
    subRange subRange: Range<Int>,
    with newCount: Int,
    elementsOf newValues: C
  ) {
    _sanityCheck(startIndex == 0, "_SliceBuffer should override this function.")
    let oldCount = self.count
    let eraseCount = subRange.count

    let growth = newCount - eraseCount
    self.count = oldCount + growth

    let elements = self.subscriptBaseAddress
    _sanityCheck(elements != nil)

    let oldTailIndex = subRange.endIndex
    let oldTailStart = elements + oldTailIndex
    let newTailIndex = oldTailIndex + growth
    let newTailStart = oldTailStart + growth
    let tailCount = oldCount - subRange.endIndex

    if growth > 0 {
      // Slide the tail part of the buffer forwards, in reverse order
      // so as not to self-clobber.
      newTailStart.moveInitializeBackwardFrom(oldTailStart, count: tailCount)

      // Assign over the original subRange
      var i = newValues.startIndex
      for j in subRange {
        elements[j] = newValues[i]
        i._successorInPlace()
      }
      // Initialize the hole left by sliding the tail forward
      for j in oldTailIndex..<newTailIndex {
        (elements + j).initialize(with: newValues[i])
        i._successorInPlace()
      }
      _expectEnd(i, newValues)
    }
    else { // We're not growing the buffer
      // Assign all the new elements into the start of the subRange
      var i = subRange.startIndex
      var j = newValues.startIndex
      for _ in 0..<newCount {
        elements[i] = newValues[j]
        i._successorInPlace()
        j._successorInPlace()
      }
      _expectEnd(j, newValues)

      // If the size didn't change, we're done.
      if growth == 0 {
        return
      }

      // Move the tail backward to cover the shrinkage.
      let shrinkage = -growth
      if tailCount > shrinkage {   // If the tail length exceeds the shrinkage

        // Assign over the rest of the replaced range with the first
        // part of the tail.
        newTailStart.moveAssignFrom(oldTailStart, count: shrinkage)

        // Slide the rest of the tail back
        oldTailStart.moveInitializeFrom(
          oldTailStart + shrinkage, count: tailCount - shrinkage)
      }
      else {                      // Tail fits within erased elements
        // Assign over the start of the replaced range with the tail
        newTailStart.moveAssignFrom(oldTailStart, count: tailCount)

        // Destroy elements remaining after the tail in subRange
        (newTailStart + tailCount).deinitialize(
          count: shrinkage - tailCount)
      }
    }
  }
}
