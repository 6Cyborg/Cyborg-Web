# Bloc « intl » d'orbita.config (get_intl_profile_config, simplifié).
# navigator.languages = accept_languages (fidèle) ; langue auto basée sur la tz
# si autoLang, sinon celle du profil. app_locale = préfixe de la 1re langue.
# Entrée : le profil. Argument : --argjson tz <geo.myip.link>.
(.autoLang // true) as $auto
| ((.navigator.language // "en-US")|split(",")[0]) as $bl
| (if (($auto|not) or (($tz.languages // "")=="")) then [$bl]
   else ($tz.languages|split(",")[0]) as $f
     | ((if (($tz.country // "")!="") then ["\($f)-\($tz.country)", $f] else [$f] end) + ["en-US","en"])
   end) as $a0
| ($a0 | reduce .[] as $x ([]; if index($x) then . else .+[$x] end)) as $arr
| ($arr[0]|split("-")[0]) as $main
| {accept_languages:($arr|join(",")), selected_languages:($arr|join(",")), app_locale:$main, forced_languages:[$main]}
