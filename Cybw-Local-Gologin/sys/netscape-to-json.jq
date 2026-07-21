[ inputs
  | split("\t")
  | (.[5] | tonumber? // 0) as $exp
  | { name: .[2], value: .[3], domain: .[0], path: .[1],
      size: ((.[2] | length) + (.[3] | length)),
      httpOnly: (.[6] == "1"),
      secure: (.[4] | ascii_upcase == "TRUE"),
      session: ($exp == 0),
      priority: "Medium", sourceScheme: "Unset", sourcePort: -1 }
  | if .session then . else . + { expires: $exp } end
]
| reduce .[] as $c ({}; .["\($c.domain)|\($c.path)|\($c.name)"] = $c)
| [ .[] ]
