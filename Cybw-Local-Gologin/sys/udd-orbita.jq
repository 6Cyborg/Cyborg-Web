{
  intl: (
    (.autoLang // true) as $auto
    | ((.navigator.language // "en-US")|split(",")[0]) as $bl
    | (if (($auto|not) or (($tz.languages // "")=="")) then [$bl]
       else ($tz.languages|split(",")[0]) as $f
         | ((if (($tz.country // "")!="") then ["\($f)-\($tz.country)", $f] else [$f] end) + ["en-US","en"])
       end) as $a0
    | ($a0 | reduce .[] as $x ([]; if index($x) then . else .+[$x] end)) as $arr
    | ($arr[0]|split("-")[0]) as $main
    | {accept_languages:($arr|join(",")), selected_languages:($arr|join(",")), app_locale:$main, forced_languages:[$main]}
  ),
  gologin: ({ profile_token: "" } + ({
    webGpu: (.webGpu // {}),
    webgl: { metadata: { vendor: (.webGLMetadata.vendor // ""), renderer: (.webGLMetadata.renderer // ""), mode: ((.webGLMetadata.mode // "") == "mask") } },
    webglParams: (.webglParams // {}),
    webRTC: (.webRTC // {}),
    plugins: { all_enable: (.plugins.enableVulnerable // true), flash_enable: (.plugins.enableFlash // true) },
    audioContext: { enable: ((.audioContext.mode // "off") != "off"), noiseValue: (.audioContext.noise // "") },
    canvasMode: (.canvas.mode // ""),
    canvasNoise: (.canvas.noise // ""),
    webgl_noice_enable: ((.webGL.mode // "") == "noise"),
    webglNoiceEnable: ((.webGL.mode // "") == "noise"),
    webgl_noise_enable: ((.webGL.mode // "") == "noise"),
    client_rects_noise_enable: ((.clientRects.mode // "") == "noise"),
    webgl_noise_value: (.webGL.noise),
    webglNoiseValue: (.webGL.noise),
    getClientRectsNoice: (.clientRects.noise // .webGL.getClientRectsNoise)
  } | with_entries(select(.value != null))))
}
