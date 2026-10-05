//
//  HexapodSceneView.swift
//  AsteriskServer
//
//  SceneKit 3D hexapod visualizer. Loads the real CAD (7 labeled usdz parts, all
//  in the shared assembly frame) and articulates it as a RIGID SKELETON: each leg
//  is built once in its assembled rest pose as a parented chain
//    legRoot → coxaYaw(mount) → [coxa+femurServo, femurPitch(hip) →
//       [femur, tibiaPitch(knee) → [tibia+tibiaServo]]]
//  and driven by rotating the three pivots by the gait's joint-angle deltas
//  (derived from the FK joint chain). Parts are rigidly parented, so nothing can
//  scatter — the leg only bends at the three real joints. The frame and coxa
//  servos are static on the body. Camera is locked to the body.
//

import SwiftUI
import SceneKit
import simd

struct HexapodSceneView: UIViewRepresentable {
  let joints: [[SIMD3<Double>]]
  let touches: [Double]

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> SCNView {
    let view = SCNView()
    view.backgroundColor = .clear
    view.antialiasingMode = .multisampling4X
    view.allowsCameraControl = true
    view.autoenablesDefaultLighting = false
    // On-demand rendering: the view redraws when the scene changes (each pose
    // update), so live motion still animates without burning the main thread —
    // continuous redraw competes with the main-actor comms loop and drops BPS.
    let scene = SCNScene()
    view.scene = scene
    context.coordinator.build(in: scene, view: view)
    context.coordinator.update(joints: joints, touches: touches)
    return view
  }

  func updateUIView(_ view: SCNView, context: Context) {
    context.coordinator.update(joints: joints, touches: touches)
  }

  final class Coordinator {
    private var frameNode: SCNNode?
    private var coxaServos: [SCNNode] = []
    private var legRoots: [SCNNode] = []
    private var coxaYaws: [SCNNode] = []
    private var femurPitches: [SCNNode] = []
    private var tibiaPitches: [SCNNode] = []
    private var tibiaMats: [[SCNMaterial]] = []
    private var ready = false
    private weak var scnView: SCNView?
    private var camNode: SCNNode?
    private var cameraAnchored = false
    // Initial framing relative to the frame center: elevated 3/4 view.
    private let camH: Float = 7.5      // camera height above the frame center
    private let camD: Float = 19      // horizontal camera distance
    private let camAimY: Float = -1   // vertical compose offset above the frame center
    // Camera azimuth around the vertical: 0 looks at the hexapod's back, 180 at
    // its front. Kept head-on; the turn is done by spinning the robot, not the
    // camera, so the view can never look rolled.
    private let camAz: Float = 180
    // Turntable: spin the whole robot about its own vertical axis (degrees).
    // Positive = counter-clockwise viewed from above. Camera stays level.
    private let turntableDeg: Float = 20

    private let scale: Float = 0.02
    // Palette: body/joints faded black; shields AND the servo bodies grey.
    private let fadedBlack = UIColor(hex: 0x36363b)
    private let shieldGrey = UIColor(hex: 0x9c9ca1)

    // Exact Fusion joints (assembly frame, mm). The CAD is the L2 (left-middle)
    // leg assembly, origin at the hip (femur servo joint).
    private let restHip = SIMD3<Float>(0, 0, 0)
    private let restKnee = SIMD3<Float>(-65.553, 0, 45.857)
    private let restFoot = SIMD3<Float>(-95.0, 26.0, -78.0)
    // Coxa yaw axis = the coxa servo's output shaft (frame side). The coxa
    // rotates about this vertical axis; only x,y matter for a yaw.
    private let restYawPivot = SIMD3<Float>(46.0, 25.82, -3.6)
    // The frame's central vertical axis (from the frame mesh's bracket holes,
    // which are symmetric about y = 25.817).
    private let frameCenter = SIMD3<Float>(124.498, 25.817, 0)
    // Per-arm servo-shaft positions and arm-axis yaw relative to the L2 arm,
    // measured from the frame mesh's servo-bracket hole patterns (flank pairs
    // 10 mm apart, shaft 31 mm outboard of the flank midpoint — calibrated on
    // L2). Corner arms are NOT radial: their axes run at exactly +-45 deg and
    // sit 8.07 deg off the center->shaft radial, which is precisely the
    // original firmware's +-8 deg coxaAttach offsets for corner legs. Right
    // arms are the x-mirror of the left (about x = 124.498).
    private let armShaft: [SIMD3<Float>] = [
      SIMD3(63.83, 106.66, -3.6),   // L1 front-left
      SIMD3(46.0, 25.82, -3.6),     // L2 mid-left (the CAD's home arm)
      SIMD3(63.82, -54.97, -3.6),   // L3 back-left
      SIMD3(185.17, 106.66, -3.6),  // R1 front-right
      SIMD3(203.0, 25.82, -3.6),    // R2 mid-right
      SIMD3(185.18, -54.97, -3.6),  // R3 back-right
    ]
    private let armYaw: [Float] = [-.pi / 4, 0, .pi / 4, .pi / 4, 0, -.pi / 4]
    // Template-side mirror for the right legs (across the shaft's x-plane; the
    // shaft is re-anchored explicitly so this equals the robot's global mirror).
    private let mirrorX = simd_float3x3(columns: (SIMD3<Float>(-1, 0, 0),
                                                  SIMD3<Float>(0, 1, 0),
                                                  SIMD3<Float>(0, 0, 1)))

    // Rest references (computed in build()).
    // The femur and tibia share one hinge: horizontal, perpendicular to the femur
    // bone's vertical plane (the hip and knee servos are parallel). NOT the
    // femur-tibia plane normal, which is tilted ~10 deg off horizontal by the
    // tibia's out-of-plane splay — pitching about that tilted axis rolls the
    // segments slightly.
    private var restPitchAxis = SIMD3<Float>(0, -1, 0)
    private var assemblyRadial = SIMD3<Float>(-1, 0, 0)

    func build(in scene: SCNScene, view: SCNView) {
      restPitchAxis = simd_normalize(simd_cross(up, horiz(restKnee - restHip)))
      assemblyRadial = simd_normalize(horiz(restYawPivot - frameCenter))

      let camera = SCNCamera()
      camera.zNear = 0.1; camera.zFar = 2000; camera.fieldOfView = 46
      let camNode = SCNNode(); camNode.camera = camera
      camNode.position = SCNVector3(0, 9, 24)
      camNode.look(at: SCNVector3(0, -2.0, 0))
      scene.rootNode.addChildNode(camNode)
      view.pointOfView = camNode
      // The precise orbit pivot (the frame center in scene space) is anchored on
      // the first ready frame in update(), once the body transform is known.
      self.camNode = camNode
      self.scnView = view

      let key = SCNLight(); key.type = .directional; key.intensity = 620
      let keyNode = SCNNode(); keyNode.light = key
      keyNode.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 5, 0)
      scene.rootNode.addChildNode(keyNode)
      let fill = SCNLight(); fill.type = .omni; fill.intensity = 420
      let fillNode = SCNNode(); fillNode.light = fill; fillNode.position = SCNVector3(-8, 10, 8)
      scene.rootNode.addChildNode(fillNode)
      let ambient = SCNLight(); ambient.type = .ambient; ambient.intensity = 480
      let ambientNode = SCNNode(); ambientNode.light = ambient
      scene.rootNode.addChildNode(ambientNode)

      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self else { return }
        let frame = self.load("Frame", tint: self.fadedBlack)
        let coxa = self.load("Coxa", tint: self.fadedBlack)
        let femurServo = self.load("FemurServo", tint: self.fadedBlack)
        let femur = self.load("Femur", tint: self.fadedBlack)
        let tibia = self.load("Tibia", tint: self.fadedBlack, shieldTint: self.shieldGrey)
        let tibiaServo = self.load("TibiaServo", tint: self.fadedBlack)
        let coxaServo = self.load("CoxaServo", tint: self.fadedBlack)
        DispatchQueue.main.async {
          if let frame { scene.rootNode.addChildNode(frame); self.frameNode = frame }
          guard let template = self.buildLegTemplate(coxa: coxa, femurServo: femurServo,
                                                     femur: femur, tibia: tibia, tibiaServo: tibiaServo)
          else { return }
          for _ in 0..<6 {
            let cs = coxaServo?.clone() ?? SCNNode()
            scene.rootNode.addChildNode(cs); self.coxaServos.append(cs)
            let leg = template.clone()
            scene.rootNode.addChildNode(leg)
            self.legRoots.append(leg)
            self.coxaYaws.append(leg.childNode(withName: "coxaYaw", recursively: true)!)
            self.femurPitches.append(leg.childNode(withName: "femurPitch", recursively: true)!)
            let tp = leg.childNode(withName: "tibiaPitch", recursively: true)!
            self.tibiaPitches.append(tp)
            self.tibiaMats.append(self.tipMaterials(of: tp))
          }
          self.ready = true
          if let j = self.lastJoints { self.update(joints: j, touches: self.lastTouches) }
        }
      }
    }

    /// Build one leg as a rigid parented chain in the assembly rest pose.
    private func buildLegTemplate(coxa: SCNNode?, femurServo: SCNNode?, femur: SCNNode?,
                                  tibia: SCNNode?, tibiaServo: SCNNode?) -> SCNNode? {
      guard let coxa, let femur, let tibia else { return nil }
      let legRoot = SCNNode()

      let coxaYaw = SCNNode(); coxaYaw.name = "coxaYaw"
      coxaYaw.simdPosition = restYawPivot
      legRoot.addChildNode(coxaYaw)
      let coxaHolder = SCNNode(); coxaHolder.simdPosition = -restYawPivot
      coxaHolder.addChildNode(coxa); if let femurServo { coxaHolder.addChildNode(femurServo) }
      coxaYaw.addChildNode(coxaHolder)

      let femurPitch = SCNNode(); femurPitch.name = "femurPitch"
      femurPitch.simdPosition = restHip - restYawPivot
      coxaYaw.addChildNode(femurPitch)
      let femurHolder = SCNNode(); femurHolder.simdPosition = -restHip
      femurHolder.addChildNode(femur)
      femurPitch.addChildNode(femurHolder)

      let tibiaPitch = SCNNode(); tibiaPitch.name = "tibiaPitch"
      tibiaPitch.simdPosition = restKnee - restHip
      femurPitch.addChildNode(tibiaPitch)
      let tibiaHolder = SCNNode(); tibiaHolder.simdPosition = -restKnee
      tibiaHolder.addChildNode(tibia); if let tibiaServo { tibiaHolder.addChildNode(tibiaServo) }
      tibiaPitch.addChildNode(tibiaHolder)

      return legRoot
    }

    private var lastJoints: [[SIMD3<Double>]]?
    private var lastTouches: [Double] = []

    func update(joints jd: [[SIMD3<Double>]], touches: [Double]) {
      guard jd.count == 6, jd.allSatisfy({ $0.count == 4 }) else { return }
      lastJoints = jd; lastTouches = touches
      guard ready else { return }
      let joints = jd.map { $0.map { SIMD3<Float>($0) } }
      let mounts = joints.map { $0[0] }
      let center = mounts.reduce(SIMD3<Float>(repeating: 0), +) / 6

      let ma = simd_float3x3(columns: (SIMD3<Float>(scale, 0, 0),
                                       SIMD3<Float>(0, 0, -scale),
                                       SIMD3<Float>(0, scale, 0)))

      // Body placement: the CAD lives in L2's (leg index 1) assembly frame, so
      // placing the body = placing L2's arm — yaw the assembly radial onto L2's
      // gait radial and put L2's coxa pivot at its gait mount. The frame and
      // all six arm shafts hang rigidly off this one transform.
      let radial1 = simd_normalize(horiz(mounts[1] - center))
      let theta1 = signedAngle(from: assemblyRadial, to: radial1, about: up)
      let linear1 = ma * simd_float3x3(simd_quatf(angle: theta1, axis: up))
      let body = mat4(linear1, ma * (mounts[1] - center) - linear1 * restYawPivot)

      // Turntable: rigidly spin the whole robot about the vertical axis through
      // the frame center (scene up = +y). Camera stays level, so this is a true
      // turntable rotation of the object — never a camera roll. Applied to the
      // frame and every leg/servo below.
      let f4 = body * SIMD4<Float>(frameCenter, 1)
      let fc = SIMD3<Float>(f4.x, f4.y, f4.z)
      let ry = simd_float3x3(simd_quatf(angle: turntableDeg * .pi / 180, axis: SIMD3<Float>(0, 1, 0)))
      let turn = mat4(ry, fc - ry * fc)
      frameNode?.simdTransform = turn * body

      // Anchor the camera to the frame center (in scene space) once the body
      // transform is known: the orbit pivot is the frame center (on the turntable
      // axis, so unaffected by the spin), and the initial framing is a level,
      // elevated 3/4 view composed to sit in the middle of the screen. Done once —
      // re-setting would fight the user's own camera drags.
      if !cameraAnchored, let cam = camNode {
        scnView?.defaultCameraController.target = SCNVector3(fc)
        let az = camAz * .pi / 180
        cam.simdPosition = fc + SIMD3<Float>(camD * sin(az), camH, camD * cos(az))
        cam.look(at: SCNVector3(fc + SIMD3<Float>(0, camAimY, 0)))
        cameraAnchored = true
      }

      for leg in 0..<6 {
        let j = joints[leg]
        let mirror = leg >= 3

        // Base placement straight from the CAD arm table: yaw the (mirrored)
        // template to this arm's axis and put its shaft at this arm's shaft,
        // both pushed through the body transform. Rigid by construction — the
        // gait only ever drives the three pivots.
        let yaw = theta1 + armYaw[leg]
        var rot = simd_float3x3(simd_quatf(angle: yaw, axis: up))
        if mirror { rot = rot * mirrorX }
        let linear = ma * rot
        let p = body * SIMD4<Float>(armShaft[leg], 1)
        let trans = SIMD3<Float>(p.x, p.y, p.z) - linear * restYawPivot
        let legMat = turn * mat4(linear, trans)
        legRoots[leg].simdTransform = legMat
        if coxaServos.indices.contains(leg) { coxaServos[leg].simdTransform = legMat }

        // Direction-matching: bring the gait bones into the leg's assembly frame
        // (undo the base yaw + mirror), then rotate each pivot so its rest bone
        // points along the gait bone — hierarchically (coxa yaw, then femur, then
        // tibia), which is robust to the CAD/kinematic geometry mismatch. The
        // corner arms' 8-deg off-radial mounting is absorbed by the coxa yaw,
        // exactly like the real robot's coxaAttach offsets.
        let qInv = simd_quatf(angle: -yaw, axis: up)
        func toAsm(_ b: SIMD3<Float>) -> SIMD3<Float> {
          let v = qInv.act(b)
          return mirror ? mirrorX * v : v
        }
        let gFemur = toAsm(j[2] - j[1])
        let gTibia = toAsm(j[3] - j[2])
        let gLeg = toAsm(j[3] - j[0])

        let da = signedAngle(from: horiz(restFoot - restYawPivot), to: horiz(gLeg), about: up)
        let qa = simd_quatf(angle: -da, axis: up)
        let tFemur = qa.act(gFemur)
        let db = signedAngle(from: restKnee - restHip, to: tFemur, about: restPitchAxis)
        let qb = simd_quatf(angle: -db, axis: restPitchAxis)
        let tTibia = qb.act(qa.act(gTibia))
        let dc = signedAngle(from: restFoot - restKnee, to: tTibia, about: restPitchAxis)

        coxaYaws[leg].simdRotation = axisAngle(up, da)
        femurPitches[leg].simdRotation = axisAngle(restPitchAxis, db)
        tibiaPitches[leg].simdRotation = axisAngle(restPitchAxis, dc)

        let touched = touches.indices.contains(leg) && touches[leg].isFinite && touches[leg] > 0.5
        for m in tibiaMats[leg] { m.emission.contents = touched ? UIColor(hex: 0xff3a3a) : UIColor.black }
      }
    }

    // MARK: math helpers

    private let up = SIMD3<Float>(0, 0, 1)
    private func horiz(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, 0) }
    private func axisAngle(_ axis: SIMD3<Float>, _ angle: Float) -> SIMD4<Float> {
      SIMD4<Float>(axis.x, axis.y, axis.z, angle)
    }
    private func signedAngle(from a: SIMD3<Float>, to b: SIMD3<Float>, about n: SIMD3<Float>) -> Float {
      let ap = a - simd_dot(a, n) * n, bp = b - simd_dot(b, n) * n
      let la = simd_length(ap), lb = simd_length(bp)
      guard la > 1e-6, lb > 1e-6 else { return 0 }
      let u = ap / la, v = bp / lb
      return atan2(simd_dot(simd_cross(u, v), n), simd_dot(u, v))
    }
    private func mat4(_ l: simd_float3x3, _ t: SIMD3<Float>) -> simd_float4x4 {
      var m = matrix_identity_float4x4
      m.columns.0 = SIMD4(l.columns.0, 0); m.columns.1 = SIMD4(l.columns.1, 0)
      m.columns.2 = SIMD4(l.columns.2, 0); m.columns.3 = SIMD4(t, 1)
      return m
    }

    // MARK: loading

    /// Tint the STRUCTURAL materials (steel / light-grey opaque) of a part to
    /// `tint`, leaving servo-body materials (blue/plastic/white/enamel) as CAD.
    /// The tibia's shield (the big chunky outer cover) takes `shieldTint`. When
    /// `diag` is set, meshes are colored by shape group to identify parts.
    private func load(_ name: String, tint: UIColor? = nil, shieldTint: UIColor? = nil,
                      diag: Bool = false) -> SCNNode? {
      guard let url = Bundle.main.url(forResource: name, withExtension: "usdz"),
            let scene = try? SCNScene(url: url, options: nil) else { return nil }
      let holder = SCNNode()
      scene.rootNode.childNodes.forEach { holder.addChildNode($0) }
      holder.enumerateChildNodes { node, _ in
        guard let geo = node.geometry else { return }
        let (lo, hi) = node.boundingBox
        let d = [abs(Float(hi.x - lo.x)), abs(Float(hi.y - lo.y)), abs(Float(hi.z - lo.z))]
        let mn = d.min() ?? 0, mx = d.max() ?? 0
        let thinPlate = mn > 1e-4 && mx / mn > 4.5
        // The shield is the big chunky curved cover: large but not a thin plate.
        let isShield = mx > 6 && !thinPlate
        let diagColor: UIColor? = !diag ? nil
          : thinPlate ? UIColor(hex: 0xff3030)          // thin plate → red
          : isShield ? UIColor(hex: 0x30d030)           // chunky cover → green
          : UIColor(hex: 0x3070ff)                       // small → blue
        geo.materials.forEach { m in
          m.isDoubleSided = true
          if m.lightingModel != .physicallyBased { m.lightingModel = .physicallyBased }
          var color = diagColor
          if !diag {
            // Shield cover and the (formerly blue) servo body → grey; all else → black.
            if isBlue(m) || (shieldTint != nil && isShield) { color = shieldGrey }
            else { color = tint }
          }
          if let color {
            m.diffuse.contents = color
            m.metalness.contents = 0.0
            m.roughness.contents = 0.7
            m.specular.contents = UIColor(white: 0.25, alpha: 1)
          }
        }
      }
      return holder
    }

    /// Only the servo's blue anodized/plastic body is kept as CAD; everything
    /// else (steel, opaque, silicone, enamel, grey plastic) is recolored. Keys on
    /// material name, falling back to a distinctly blue diffuse (b ≫ r, g).
    private func isBlue(_ m: SCNMaterial) -> Bool {
      let n = (m.name ?? "").lowercased()
      if n.contains("blue") { return true }
      if n.contains("steel") || n.contains("opaque") || n.contains("silicone")
          || n.contains("enamel") || n.contains("grey") || n.contains("gray") { return false }
      if let c = m.diffuse.contents as? UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return b > r + 0.15 && b > g + 0.1
      }
      return false
    }

    /// Deep-copy every mesh under the tibia pivot (so each leg tints
    /// independently), but return only the materials of the mesh nearest the
    /// foot — the TIP — so a touch reddens just the tip, not the whole lower leg
    /// or the tibia servo. `pivot` is the tibiaPitch node (origin at the knee).
    private func tipMaterials(of pivot: SCNNode) -> [SCNMaterial] {
      let footInPivot = restFoot - restKnee
      var tip: SCNNode?
      var bestD = Float.greatestFiniteMagnitude
      pivot.enumerateHierarchy { n, _ in
        guard let g = n.geometry, let gc = g.copy() as? SCNGeometry else { return }
        gc.materials = gc.materials.map { $0.copy() as! SCNMaterial }
        n.geometry = gc
        let (lo, hi) = n.boundingBox
        let cLocal = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
        let c = pivot.convertPosition(cLocal, from: n)
        let d = simd_length(SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z)) - footInPivot)
        if d < bestD { bestD = d; tip = n }
      }
      return tip?.geometry?.materials ?? []
    }
  }
}

private extension UIColor {
  convenience init(hex: UInt32) {
    self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
              green: CGFloat((hex >> 8) & 0xFF) / 255,
              blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
  }
}
