( {
    profile_id: .id,
    name: .name,
    is_m1: ((((.os // "") == "mac") and ((.osSpec // "")|test("M"))) or (.isM1 // false)),
    navigator: { platform: (.navigator.platform // ""), max_touch_points: (.navigator.maxTouchPoints // 0) },
    dns: (.dns // {}),
    proxy: { username: ($proxy.user // ""), password: ($proxy.pass // "") },
    webRTC: (.webRTC // {}),
    screenWidth: ((.navigator.resolution // "1920x1080")|split("x")[0]|tonumber),
    screenHeight: ((.navigator.resolution // "1920x1080")|split("x")[1]|tonumber),
    userAgent: (.navigator.userAgent // ""),
    webGl: { vendor: (.webGLMetadata.vendor // ""), renderer: (.webGLMetadata.renderer // ""), mode: ((.webGLMetadata.mode // "") == "mask") },
    webgl: { metadata: { vendor: (.webGLMetadata.vendor // ""), renderer: (.webGLMetadata.renderer // ""), mode: ((.webGLMetadata.mode // "") == "mask") } },
    mobile: { enable: ((.os // "") == "android"), width: (.screenWidth // 1920), height: (.screenHeight // 1080), device_scale_factor: (.devicePixelRatio // 1) },
    webglParams: (.webglParams // {}),
    webGpu: (.webGpu // {}),
    webgl_noice_enable: ((.webGL.mode // "") == "noise"),
    webglNoiceEnable: ((.webGL.mode // "") == "noise"),
    webgl_noise_enable: ((.webGL.mode // "") == "noise"),
    webgl_noise_value: (.webGL.noise),
    webglNoiseValue: (.webGL.noise),
    getClientRectsNoice: (.clientRects.noise // .webGL.getClientRectsNoise),
    client_rects_noise_enable: ((.clientRects.mode // "") == "noise"),
    media_devices: { enable: (.mediaDevices.enableMasking // true), uid: (.mediaDevices.uid // ""), audioInputs: (.mediaDevices.audioInputs // 1), audioOutputs: (.mediaDevices.audioOutputs // 1), videoInputs: (.mediaDevices.videoInputs // 1) },
    doNotTrack: (.navigator.doNotTrack // false),
    plugins: { all_enable: (.plugins.enableVulnerable // true), flash_enable: (.plugins.enableFlash // true) },
    storage: { enable: (.storage.local // true) },
    audioContext: { enable: ((.audioContext.mode // "off") != "off"), noiseValue: (.audioContext.noise // "") },
    canvas: { mode: (.canvas.mode // "") },
    canvasMode: (.canvas.mode // ""),
    canvasNoise: (.canvas.noise // ""),
    languages: ((.navigator.language // "en-US")|split(",")[0]),
    langHeader: (.navigator.language // ""),
    hardwareConcurrency: (.navigator.hardwareConcurrency // 2),
    deviceMemory: ((.navigator.deviceMemory // 2) * 1024),
    geolocation: { mode: (.geolocation.mode // "prompt"),
                   latitude: (try ($tz.ll[0]|tonumber) catch 0),
                   longitude: (try ($tz.ll[1]|tonumber) catch 0),
                   accuracy: (try ($tz.accuracy|tonumber) catch 0) },
    timezone: { id: ($tz.timezone // "") }
  }
  + (if (($proxy.server // "") != "") then
      { proxy: { mode: "fixed_servers", schema: ($proxy.scheme // ""), username: ($proxy.user // ""), password: ($proxy.pass // ""), server: $proxy.server } }
     else {} end)
) as $g
| $base
| .gologin = $g
| if (($proxy.server // "") != "") then .proxy = { mode: "fixed_servers", server: $proxy.server } else . end
