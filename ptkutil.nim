template first*(a: openarray): auto = a[0]

template last*(a: openarray): auto = a[len(a)-1]
