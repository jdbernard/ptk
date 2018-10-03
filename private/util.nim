template first*(a: openarray): auto = a[0]

template last*(a: openarray): auto = a[len(a)-1]

proc flatten*[T](a: seq[seq[T]]): seq[T] =
  result = @[]
  for subseq in a:
    result.add(subseq)


proc raiseEx*(reason: string): void = raise newException(Exception, reason)
