import "design-result-limits" as $limits;

# Return a predicate for recorder selects; reject without including judgment text.
def dr_lines($field):
  $limits[0] as $bounds | $bounds.maxItems[$field] as $maximum |
  if type != "array" then error("design-result: \($field): expected an array")
  elif length > $maximum then
    error("design-result: \($field): item count \(length) exceeds maximum \($maximum)")
  else all(to_entries[]; .key as $index | .value |
    if type != "string" then error("design-result: \($field)[\($index)]: expected a string")
    elif length < $bounds.minLength then
      error("design-result: \($field)[\($index)]: length \(length) is below minimum \($bounds.minLength) characters")
    elif length > $bounds.maxLength then
      error("design-result: \($field)[\($index)]: length \(length) exceeds maximum \($bounds.maxLength) characters")
    elif test("[[:cntrl:]]") then
      error("design-result: \($field)[\($index)]: control characters are forbidden")
    else true end)
  end;
