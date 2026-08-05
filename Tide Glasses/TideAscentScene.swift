//
//  TideAscentScene.swift
//  Tide Glasses
//
//  The visual renderer for Ascent. Game rules stay in TideDiveGame; this file
//  turns that state into a lit, animated 3D flight corridor.
//

import SceneKit
import SwiftUI

struct TideAscentScene: UIViewRepresentable {
    let altitude: Double
    let position: Double
    let obstacles: [TideDiveGame.Obstacle]
    let zone: TideDiveGame.Zone
    let phase: TideDiveGame.Phase

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SCNView {
        context.coordinator.makeView()
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.update(
            altitude: altitude,
            position: position,
            obstacles: obstacles,
            zone: zone,
            phase: phase
        )
    }

    @MainActor
    final class Coordinator {
        private let scene = SCNScene()
        private let cameraNode = SCNNode()
        private let cameraTarget = SCNNode()
        private let player = SCNNode()
        private let obstacleRoot = SCNNode()
        private let trackRoot = SCNNode()
        private let ambientLight = SCNNode()
        private let keyLight = SCNNode()
        private let rimLight = SCNNode()

        private var obstacleNodes: [UUID: SCNNode] = [:]
        private var trackRows: [SCNNode] = []
        private var jetStreams: [SCNParticleSystem] = []
        private var lastZone: TideDiveGame.Zone?
        private var previousPosition = Double(TideDiveGame.laneCount / 2)

        func makeView() -> SCNView {
            let view = SCNView(frame: .zero)
            view.scene = scene
            view.backgroundColor = .clear
            view.isOpaque = false
            // SceneKit at the phone's native 3x scale plus 4x MSAA was doing
            // far more GPU work than this portrait runner needs.
            view.contentScaleFactor = min(UIScreen.main.scale, 2)
            view.antialiasingMode = .multisampling2X
            view.preferredFramesPerSecond = 60
            view.rendersContinuously = false
            view.isPlaying = true
            view.allowsCameraControl = false
            view.autoenablesDefaultLighting = false

            configureCamera()
            configureLights()
            configureTrack()
            configurePlayer()

            scene.rootNode.addChildNode(trackRoot)
            scene.rootNode.addChildNode(obstacleRoot)
            scene.rootNode.addChildNode(player)
            scene.rootNode.addChildNode(cameraTarget)
            scene.rootNode.addChildNode(cameraNode)
            scene.rootNode.addChildNode(ambientLight)
            scene.rootNode.addChildNode(keyLight)
            scene.rootNode.addChildNode(rimLight)

            scene.background.contents = UIColor.clear
            scene.fogStartDistance = 34
            scene.fogEndDistance = 74
            view.pointOfView = cameraNode
            return view
        }

        func update(
            altitude: Double,
            position: Double,
            obstacles: [TideDiveGame.Obstacle],
            zone: TideDiveGame.Zone,
            phase: TideDiveGame.Phase
        ) {
            if lastZone?.rawValue != zone.rawValue {
                applyLighting(for: zone)
                lastZone = zone
            }

            updateTrack(altitude: altitude)
            updatePlayer(position: position, altitude: altitude, isFlying: phase == .playing)
            updateObstacles(obstacles, altitude: altitude)

            let flyingRate: CGFloat = phase == .playing ? 72 : 0
            jetStreams.forEach { $0.birthRate = flyingRate }
            previousPosition = position
        }

        // MARK: Scene setup

        private func configureCamera() {
            let camera = SCNCamera()
            camera.fieldOfView = 60
            camera.zNear = 0.1
            camera.zFar = 110
            camera.wantsHDR = false
            camera.bloomIntensity = 0
            camera.vignettingIntensity = 0
            cameraNode.camera = camera
            // Pull back enough that the player model remains completely inside
            // the frame in both edge lanes, including its arms and jet pack.
            cameraNode.position = SCNVector3(0, 1.35, 14.2)

            cameraTarget.position = SCNVector3(0, 0.4, -13)
            let look = SCNLookAtConstraint(target: cameraTarget)
            look.isGimbalLockEnabled = true
            cameraNode.constraints = [look]
        }

        private func configureLights() {
            let ambient = SCNLight()
            ambient.type = .ambient
            ambient.intensity = 520
            ambient.color = UIColor(red: 0.34, green: 0.57, blue: 0.82, alpha: 1)
            ambientLight.light = ambient

            let key = SCNLight()
            key.type = .directional
            key.intensity = 1_550
            key.castsShadow = false
            keyLight.light = key
            keyLight.eulerAngles = SCNVector3(-0.8, -0.55, -0.25)

            let rim = SCNLight()
            rim.type = .omni
            rim.intensity = 1_150
            rim.attenuationStartDistance = 2
            rim.attenuationEndDistance = 26
            rim.color = UIColor(red: 0.15, green: 0.92, blue: 1, alpha: 1)
            rimLight.light = rim
            rimLight.position = SCNVector3(-4, 1.5, 4)
        }

        private func configureTrack() {
            let current = material(
                UIColor(red: 0.18, green: 0.92, blue: 1, alpha: 1),
                emission: UIColor(red: 0.04, green: 0.62, blue: 0.92, alpha: 1),
                opacity: 0.72
            )

            for rowIndex in 0..<11 {
                let row = SCNNode()
                row.name = "current-row-\(rowIndex)"

                for lane in 0..<TideDiveGame.laneCount {
                    let dash = SCNBox(width: 0.07, height: 0.026, length: 0.9, chamferRadius: 0.025)
                    dash.materials = [current]
                    let node = SCNNode(geometry: dash)
                    node.position.x = laneX(Double(lane))
                    row.addChildNode(node)
                }

                let crossbar = SCNBox(width: 5.55, height: 0.018, length: 0.035, chamferRadius: 0.018)
                let crossMaterial = material(
                    UIColor.white.withAlphaComponent(0.22),
                    emission: UIColor(red: 0.08, green: 0.38, blue: 0.58, alpha: 1),
                    opacity: 0.28
                )
                crossbar.materials = [crossMaterial]
                row.addChildNode(SCNNode(geometry: crossbar))

                trackRoot.addChildNode(row)
                trackRows.append(row)
            }
        }

        private func configurePlayer() {
            player.name = "tide-rider"

            let suit = material(
                UIColor(red: 1, green: 0.23, blue: 0.12, alpha: 1),
                metalness: 0.18,
                roughness: 0.24
            )
            let suitDark = material(
                UIColor(red: 0.045, green: 0.07, blue: 0.11, alpha: 1),
                metalness: 0.5,
                roughness: 0.22
            )
            let chrome = material(
                UIColor(red: 0.62, green: 0.78, blue: 0.88, alpha: 1),
                metalness: 0.9,
                roughness: 0.12
            )
            let glass = material(
                UIColor(red: 0.15, green: 0.78, blue: 0.96, alpha: 1),
                metalness: 0.3,
                roughness: 0.08,
                emission: UIColor(red: 0.02, green: 0.25, blue: 0.38, alpha: 1),
                opacity: 0.82
            )

            let torso = SCNCapsule(capRadius: 0.42, height: 1.25)
            torso.materials = [suit]
            let torsoNode = SCNNode(geometry: torso)
            torsoNode.scale = SCNVector3(0.9, 1, 0.55)
            player.addChildNode(torsoNode)

            let helmet = SCNSphere(radius: 0.43)
            helmet.segmentCount = 32
            helmet.materials = [glass]
            let helmetNode = SCNNode(geometry: helmet)
            helmetNode.position.y = 0.82
            helmetNode.scale.z = 0.78
            player.addChildNode(helmetNode)

            let helmetBand = SCNTorus(ringRadius: 0.4, pipeRadius: 0.055)
            helmetBand.materials = [chrome]
            let helmetBandNode = SCNNode(geometry: helmetBand)
            helmetBandNode.position.y = 0.69
            helmetBandNode.eulerAngles.x = .pi / 2
            player.addChildNode(helmetBandNode)

            addLimb(to: player, at: SCNVector3(-0.48, 0.03, 0), angle: 0.42, material: suit)
            addLimb(to: player, at: SCNVector3(0.48, 0.03, 0), angle: -0.42, material: suit)
            addLeg(to: player, x: -0.23, material: suitDark)
            addLeg(to: player, x: 0.23, material: suitDark)

            let pack = SCNBox(width: 0.78, height: 0.82, length: 0.34, chamferRadius: 0.16)
            pack.materials = [suitDark]
            let packNode = SCNNode(geometry: pack)
            packNode.position = SCNVector3(0, -0.02, 0.38)
            player.addChildNode(packNode)

            for x: Float in [-0.25, 0.25] {
                let engine = SCNCylinder(radius: 0.12, height: 0.54)
                engine.radialSegmentCount = 16
                engine.materials = [chrome]
                let engineNode = SCNNode(geometry: engine)
                engineNode.position = SCNVector3(x, -0.44, 0.46)
                player.addChildNode(engineNode)

                let glow = SCNCone(topRadius: 0.035, bottomRadius: 0.14, height: 0.52)
                glow.materials = [material(
                    UIColor(red: 0.35, green: 0.95, blue: 1, alpha: 1),
                    emission: UIColor(red: 0.05, green: 0.85, blue: 1, alpha: 1)
                )]
                let glowNode = SCNNode(geometry: glow)
                glowNode.position = SCNVector3(x, -0.96, 0.46)
                glowNode.opacity = 0.92
                player.addChildNode(glowNode)

                let stream = makeJetStream()
                glowNode.addParticleSystem(stream)
                jetStreams.append(stream)
            }

            let crest = SCNBox(width: 0.11, height: 0.52, length: 0.16, chamferRadius: 0.05)
            crest.materials = [material(
                UIColor(red: 1, green: 0.72, blue: 0.08, alpha: 1),
                metalness: 0.2,
                roughness: 0.3,
                emission: UIColor(red: 0.45, green: 0.16, blue: 0, alpha: 1)
            )]
            let crestNode = SCNNode(geometry: crest)
            crestNode.position = SCNVector3(0, 1.2, 0)
            player.addChildNode(crestNode)

            player.position = SCNVector3(0, -1.7, 2.2)
            player.scale = SCNVector3(0.92, 0.92, 0.92)
            player.runAction(.repeatForever(.sequence([
                .moveBy(x: 0, y: 0.06, z: 0, duration: 0.62),
                .moveBy(x: 0, y: -0.06, z: 0, duration: 0.62)
            ])))
        }

        // MARK: Live updates

        private func updatePlayer(position: Double, altitude: Double, isFlying: Bool) {
            let targetX = laneX(position)
            let delta = position - previousPosition

            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            player.position.x = targetX
            player.eulerAngles.z = Float(-delta * 0.12)
            player.eulerAngles.y = Float(delta * 0.06)
            player.opacity = isFlying ? 1 : 0.9
            SCNTransaction.commit()

            let pulse = 0.94 + Float(sin(altitude * 0.08)) * 0.05
            jetStreams.forEach { $0.particleSize = CGFloat(0.08 * pulse) }
        }

        private func updateTrack(altitude: Double) {
            let spacing = 4.25
            let movement = (altitude * 0.064).truncatingRemainder(dividingBy: spacing)

            for (index, row) in trackRows.enumerated() {
                let distance = Double(index) * spacing - movement + 0.9
                let progress = min(max(distance / 62, 0), 1)
                row.position = SCNVector3(
                    0,
                    Float(-2.25 + progress * 6.5),
                    Float(2.2 - distance)
                )
                row.opacity = CGFloat(0.18 + (1 - progress) * 0.48)
                row.scale.x = Float(1 - progress * 0.22)
            }
        }

        private func updateObstacles(_ obstacles: [TideDiveGame.Obstacle], altitude: Double) {
            let liveIDs = Set(obstacles.map(\.id))
            for (id, node) in obstacleNodes where !liveIDs.contains(id) {
                node.removeFromParentNode()
                obstacleNodes[id] = nil
            }

            for obstacle in obstacles {
                let node: SCNNode
                if let existing = obstacleNodes[obstacle.id] {
                    node = existing
                } else {
                    node = makeObstacle(obstacle.kind)
                    node.opacity = 0
                    obstacleRoot.addChildNode(node)
                    obstacleNodes[obstacle.id] = node
                }

                let distance = obstacle.altitude - altitude
                let progress = min(max(distance / 620, 0), 1)
                let passed = max(-distance, 0)
                let fade: Double = distance < -14 ? max(0, 1 - ((-distance - 14) / 46)) : 1

                node.position = SCNVector3(
                    laneX(Double(obstacle.lane)),
                    Float(-1.58 + progress * 6.45 - passed * 0.012),
                    Float(2.1 - distance * 0.064)
                )
                node.opacity = CGFloat(fade)
            }
        }

        private func applyLighting(for zone: TideDiveGame.Zone) {
            let ambient: UIColor
            let key: UIColor
            let rim: UIColor
            let fog: UIColor

            switch zone {
            case .seabed:
                ambient = UIColor(red: 0.04, green: 0.26, blue: 0.36, alpha: 1)
                key = UIColor(red: 0.12, green: 0.72, blue: 0.84, alpha: 1)
                rim = UIColor(red: 0.46, green: 0.12, blue: 0.88, alpha: 1)
                fog = UIColor(red: 0.01, green: 0.08, blue: 0.14, alpha: 1)
            case .deep:
                ambient = UIColor(red: 0.05, green: 0.34, blue: 0.52, alpha: 1)
                key = UIColor(red: 0.14, green: 0.82, blue: 0.94, alpha: 1)
                rim = UIColor(red: 0.66, green: 0.18, blue: 0.92, alpha: 1)
                fog = UIColor(red: 0.01, green: 0.12, blue: 0.24, alpha: 1)
            case .shallows:
                ambient = UIColor(red: 0.12, green: 0.55, blue: 0.65, alpha: 1)
                key = UIColor(red: 0.72, green: 1, blue: 0.92, alpha: 1)
                rim = UIColor(red: 1, green: 0.32, blue: 0.18, alpha: 1)
                fog = UIColor(red: 0.02, green: 0.28, blue: 0.45, alpha: 1)
            case .surface:
                ambient = UIColor(red: 0.42, green: 0.68, blue: 0.82, alpha: 1)
                key = UIColor(red: 1, green: 0.88, blue: 0.62, alpha: 1)
                rim = UIColor(red: 0.05, green: 0.82, blue: 1, alpha: 1)
                fog = UIColor(red: 0.32, green: 0.68, blue: 0.86, alpha: 1)
            case .sky:
                ambient = UIColor(red: 0.45, green: 0.62, blue: 0.9, alpha: 1)
                key = UIColor(red: 1, green: 0.84, blue: 0.52, alpha: 1)
                rim = UIColor(red: 1, green: 0.22, blue: 0.38, alpha: 1)
                fog = UIColor(red: 0.31, green: 0.58, blue: 0.9, alpha: 1)
            case .space:
                ambient = UIColor(red: 0.16, green: 0.13, blue: 0.38, alpha: 1)
                key = UIColor(red: 0.55, green: 0.62, blue: 1, alpha: 1)
                rim = UIColor(red: 0.98, green: 0.18, blue: 0.72, alpha: 1)
                fog = UIColor(red: 0.015, green: 0.01, blue: 0.08, alpha: 1)
            }

            ambientLight.light?.color = ambient
            keyLight.light?.color = key
            rimLight.light?.color = rim
            scene.fogColor = fog
        }

        // MARK: Obstacles

        private func makeObstacle(_ kind: TideDiveGame.Obstacle.Kind) -> SCNNode {
            switch kind {
            case .rock: makeRock()
            case .jellyfish: makeJellyfish()
            case .fish: makeFish()
            case .bird: makeBird()
            case .satellite: makeSatellite()
            }
        }

        private func makeRock() -> SCNNode {
            let root = SCNNode()
            let colors = [
                UIColor(red: 0.28, green: 0.16, blue: 0.36, alpha: 1),
                UIColor(red: 0.12, green: 0.42, blue: 0.48, alpha: 1),
                UIColor(red: 0.55, green: 0.22, blue: 0.24, alpha: 1)
            ]

            for index in 0..<3 {
                let stone = SCNSphere(radius: index == 0 ? 0.55 : 0.36)
                stone.segmentCount = 7
                stone.materials = [material(colors[index], metalness: 0.08, roughness: 0.82)]
                let node = SCNNode(geometry: stone)
                node.position = SCNVector3(Float(index - 1) * 0.34, Float(index % 2) * 0.25, Float(index % 2) * 0.12)
                node.scale = SCNVector3(1, 0.82, 0.9)
                root.addChildNode(node)
            }

            root.runAction(.repeatForever(.rotateBy(x: 0.3, y: 1.4, z: 0.2, duration: 4.6)))
            return root
        }

        private func makeJellyfish() -> SCNNode {
            let root = SCNNode()
            let jelly = material(
                UIColor(red: 0.88, green: 0.26, blue: 1, alpha: 1),
                metalness: 0.05,
                roughness: 0.15,
                emission: UIColor(red: 0.24, green: 0.02, blue: 0.42, alpha: 1),
                opacity: 0.82
            )
            let dome = SCNSphere(radius: 0.58)
            dome.segmentCount = 28
            dome.materials = [jelly]
            let domeNode = SCNNode(geometry: dome)
            domeNode.scale.y = 0.72
            domeNode.position.y = 0.3
            root.addChildNode(domeNode)

            for index in 0..<6 {
                let tentacle = SCNCapsule(capRadius: 0.035, height: 0.72 + CGFloat(index % 2) * 0.22)
                tentacle.materials = [jelly]
                let node = SCNNode(geometry: tentacle)
                node.position = SCNVector3(Float(index - 3) * 0.14 + 0.07, -0.46, 0)
                node.eulerAngles.z = Float(index - 3) * 0.055
                root.addChildNode(node)
                node.runAction(.repeatForever(.sequence([
                    .rotateBy(x: 0, y: 0, z: 0.14, duration: 0.55 + Double(index) * 0.03),
                    .rotateBy(x: 0, y: 0, z: -0.14, duration: 0.55 + Double(index) * 0.03)
                ])))
            }
            root.runAction(.repeatForever(.sequence([
                .scale(to: 1.06, duration: 0.55),
                .scale(to: 0.94, duration: 0.55)
            ])))
            return root
        }

        private func makeFish() -> SCNNode {
            let root = SCNNode()
            let bodyMaterial = material(
                UIColor(red: 0.05, green: 0.78, blue: 0.9, alpha: 1),
                metalness: 0.24,
                roughness: 0.24,
                emission: UIColor(red: 0.01, green: 0.17, blue: 0.22, alpha: 1)
            )
            let finMaterial = material(
                UIColor(red: 1, green: 0.45, blue: 0.08, alpha: 1),
                metalness: 0.1,
                roughness: 0.32
            )

            let body = SCNSphere(radius: 0.48)
            body.segmentCount = 24
            body.materials = [bodyMaterial]
            let bodyNode = SCNNode(geometry: body)
            bodyNode.scale = SCNVector3(1.45, 0.74, 0.7)
            root.addChildNode(bodyNode)

            let tailPivot = SCNNode()
            tailPivot.position.x = -0.74
            let tail = SCNPyramid(width: 0.58, height: 0.7, length: 0.12)
            tail.materials = [finMaterial]
            let tailNode = SCNNode(geometry: tail)
            tailNode.eulerAngles.z = .pi / 2
            tailNode.position.x = -0.2
            tailPivot.addChildNode(tailNode)
            root.addChildNode(tailPivot)

            let eye = SCNSphere(radius: 0.085)
            eye.materials = [material(.white, roughness: 0.2)]
            for z: Float in [-0.32, 0.32] {
                let eyeNode = SCNNode(geometry: eye)
                eyeNode.position = SCNVector3(0.48, 0.18, z)
                root.addChildNode(eyeNode)
            }

            tailPivot.runAction(.repeatForever(.sequence([
                .rotateBy(x: 0, y: 0.42, z: 0, duration: 0.16),
                .rotateBy(x: 0, y: -0.84, z: 0, duration: 0.28),
                .rotateBy(x: 0, y: 0.42, z: 0, duration: 0.16)
            ])))
            root.runAction(.repeatForever(.sequence([
                .rotateBy(x: 0, y: 0, z: 0.08, duration: 0.5),
                .rotateBy(x: 0, y: 0, z: -0.08, duration: 0.5)
            ])))
            return root
        }

        private func makeBird() -> SCNNode {
            let root = SCNNode()
            root.name = "bird"
            let blue = material(
                UIColor(red: 0.015, green: 0.48, blue: 0.92, alpha: 1),
                metalness: 0.1,
                roughness: 0.3
            )
            let coral = material(
                UIColor(red: 0.94, green: 0.08, blue: 0.055, alpha: 1),
                metalness: 0.08,
                roughness: 0.32
            )
            let gold = material(
                UIColor(red: 1, green: 0.71, blue: 0.05, alpha: 1),
                metalness: 0.18,
                roughness: 0.25
            )
            let ink = material(
                UIColor(red: 0.035, green: 0.04, blue: 0.055, alpha: 1),
                metalness: 0.15,
                roughness: 0.18
            )

            let body = SCNSphere(radius: 0.42)
            body.segmentCount = 28
            body.materials = [blue]
            let bodyNode = SCNNode(geometry: body)
            bodyNode.position = SCNVector3(0, -0.1, 0)
            bodyNode.scale = SCNVector3(0.72, 1.18, 0.65)
            root.addChildNode(bodyNode)

            let chest = SCNSphere(radius: 0.3)
            chest.segmentCount = 24
            chest.materials = [gold]
            let chestNode = SCNNode(geometry: chest)
            chestNode.position = SCNVector3(0, -0.02, 0.29)
            chestNode.scale = SCNVector3(0.68, 1.14, 0.18)
            root.addChildNode(chestNode)

            let head = SCNSphere(radius: 0.29)
            head.segmentCount = 28
            head.materials = [coral]
            let headNode = SCNNode(geometry: head)
            headNode.position = SCNVector3(0, 0.43, 0.02)
            root.addChildNode(headNode)

            let face = SCNSphere(radius: 0.2)
            face.segmentCount = 24
            face.materials = [material(
                UIColor(red: 0.96, green: 0.91, blue: 0.72, alpha: 1),
                roughness: 0.6
            )]
            let faceNode = SCNNode(geometry: face)
            faceNode.position = SCNVector3(0, 0.43, 0.25)
            faceNode.scale = SCNVector3(0.82, 0.72, 0.18)
            root.addChildNode(faceNode)

            let beak = SCNSphere(radius: 0.14)
            beak.segmentCount = 18
            beak.materials = [ink]
            let beakNode = SCNNode(geometry: beak)
            beakNode.position = SCNVector3(0, 0.35, 0.38)
            beakNode.scale = SCNVector3(0.72, 0.92, 0.72)
            root.addChildNode(beakNode)

            for x: Float in [-0.095, 0.095] {
                let eye = SCNSphere(radius: 0.052)
                eye.segmentCount = 16
                eye.materials = [material(.white, roughness: 0.18)]
                let eyeNode = SCNNode(geometry: eye)
                eyeNode.position = SCNVector3(x, 0.49, 0.33)
                root.addChildNode(eyeNode)

                let pupil = SCNSphere(radius: 0.026)
                pupil.segmentCount = 12
                pupil.materials = [ink]
                let pupilNode = SCNNode(geometry: pupil)
                pupilNode.position = SCNVector3(x, 0.49, 0.372)
                root.addChildNode(pupilNode)
            }

            let leftWing = makeBirdWing(blue: blue, gold: gold, coral: coral, mirrored: false)
            let rightWing = makeBirdWing(blue: blue, gold: gold, coral: coral, mirrored: true)
            leftWing.position = SCNVector3(-0.18, 0.16, -0.02)
            rightWing.position = SCNVector3(0.18, 0.16, -0.02)
            root.addChildNode(leftWing)
            root.addChildNode(rightWing)

            for (index, tailMaterial) in [coral, blue, gold].enumerated() {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: -0.085, y: 0.18))
                path.addCurve(
                    to: CGPoint(x: 0, y: -0.9 - CGFloat(index) * 0.08),
                    controlPoint1: CGPoint(x: -0.07, y: -0.2),
                    controlPoint2: CGPoint(x: -0.03, y: -0.68)
                )
                path.addCurve(
                    to: CGPoint(x: 0.085, y: 0.18),
                    controlPoint1: CGPoint(x: 0.03, y: -0.68),
                    controlPoint2: CGPoint(x: 0.07, y: -0.2)
                )
                path.close()
                let tail = SCNShape(path: path, extrusionDepth: 0.055)
                tail.chamferRadius = 0.025
                tail.materials = [tailMaterial]
                let tailNode = SCNNode(geometry: tail)
                tailNode.position = SCNVector3(Float(index - 1) * 0.12, -0.42, -0.12)
                tailNode.eulerAngles.z = Float(index - 1) * -0.11
                root.addChildNode(tailNode)
            }

            leftWing.runAction(.repeatForever(.sequence([
                .rotateTo(x: 0.04, y: 0, z: 0.22, duration: 0.22, usesShortestUnitArc: true),
                .rotateTo(x: -0.08, y: 0, z: -0.24, duration: 0.28, usesShortestUnitArc: true)
            ])))
            rightWing.runAction(.repeatForever(.sequence([
                .rotateTo(x: 0.04, y: 0, z: -0.22, duration: 0.22, usesShortestUnitArc: true),
                .rotateTo(x: -0.08, y: 0, z: 0.24, duration: 0.28, usesShortestUnitArc: true)
            ])))
            root.runAction(.repeatForever(.sequence([
                .moveBy(x: 0, y: 0.035, z: 0, duration: 0.32),
                .moveBy(x: 0, y: -0.035, z: 0, duration: 0.32)
            ])))
            root.scale = SCNVector3(0.96, 0.96, 0.96)
            return root
        }

        private func makeSatellite() -> SCNNode {
            let root = SCNNode()
            let chrome = material(
                UIColor(red: 0.68, green: 0.75, blue: 0.86, alpha: 1),
                metalness: 0.9,
                roughness: 0.14
            )
            let gold = material(
                UIColor(red: 1, green: 0.58, blue: 0.05, alpha: 1),
                metalness: 0.7,
                roughness: 0.16,
                emission: UIColor(red: 0.28, green: 0.08, blue: 0, alpha: 1)
            )
            let solar = material(
                UIColor(red: 0.04, green: 0.22, blue: 0.7, alpha: 1),
                metalness: 0.55,
                roughness: 0.16,
                emission: UIColor(red: 0.02, green: 0.12, blue: 0.42, alpha: 1)
            )

            let core = SCNCapsule(capRadius: 0.25, height: 0.92)
            core.materials = [chrome]
            root.addChildNode(SCNNode(geometry: core))

            let band = SCNTorus(ringRadius: 0.28, pipeRadius: 0.07)
            band.materials = [gold]
            let bandNode = SCNNode(geometry: band)
            bandNode.eulerAngles.x = .pi / 2
            root.addChildNode(bandNode)

            for side: Float in [-1, 1] {
                let arm = SCNBox(width: 0.42, height: 0.07, length: 0.08, chamferRadius: 0.02)
                arm.materials = [chrome]
                let armNode = SCNNode(geometry: arm)
                armNode.position.x = side * 0.4
                root.addChildNode(armNode)

                let panel = SCNBox(width: 0.78, height: 0.5, length: 0.045, chamferRadius: 0.035)
                panel.materials = [solar]
                let panelNode = SCNNode(geometry: panel)
                panelNode.position.x = side * 0.98
                root.addChildNode(panelNode)
            }

            let beacon = SCNSphere(radius: 0.095)
            beacon.materials = [material(
                UIColor(red: 1, green: 0.08, blue: 0.3, alpha: 1),
                emission: UIColor(red: 1, green: 0.02, blue: 0.12, alpha: 1)
            )]
            let beaconNode = SCNNode(geometry: beacon)
            beaconNode.position.y = 0.55
            root.addChildNode(beaconNode)
            beaconNode.runAction(.repeatForever(.sequence([
                .fadeOpacity(to: 0.2, duration: 0.35),
                .fadeOpacity(to: 1, duration: 0.35)
            ])))

            root.runAction(.repeatForever(.rotateBy(x: 0.22, y: 1.1, z: 0.18, duration: 3.6)))
            return root
        }

        // MARK: Geometry helpers

        private func addLimb(to root: SCNNode, at position: SCNVector3, angle: Float, material: SCNMaterial) {
            let limb = SCNCapsule(capRadius: 0.1, height: 0.72)
            limb.materials = [material]
            let node = SCNNode(geometry: limb)
            node.position = position
            node.eulerAngles.z = angle
            root.addChildNode(node)
        }

        private func addLeg(to root: SCNNode, x: Float, material: SCNMaterial) {
            let leg = SCNCapsule(capRadius: 0.12, height: 0.72)
            leg.materials = [material]
            let node = SCNNode(geometry: leg)
            node.position = SCNVector3(x, -0.76, 0)
            node.eulerAngles.z = x < 0 ? -0.07 : 0.07
            root.addChildNode(node)
        }

        private func makeBirdWing(
            blue: SCNMaterial,
            gold: SCNMaterial,
            coral: SCNMaterial,
            mirrored: Bool
        ) -> SCNNode {
            let pivot = SCNNode()
            let direction: CGFloat = mirrored ? 1 : -1

            addBirdWingLayer(
                to: pivot,
                direction: direction,
                span: 1.48,
                rise: 0.25,
                drop: 0.31,
                depth: -0.05,
                material: blue
            )
            addBirdWingLayer(
                to: pivot,
                direction: direction,
                span: 1.12,
                rise: 0.22,
                drop: 0.22,
                depth: 0.015,
                material: gold
            )
            addBirdWingLayer(
                to: pivot,
                direction: direction,
                span: 0.72,
                rise: 0.18,
                drop: 0.14,
                depth: 0.075,
                material: coral
            )
            return pivot
        }

        private func addBirdWingLayer(
            to root: SCNNode,
            direction: CGFloat,
            span: CGFloat,
            rise: CGFloat,
            drop: CGFloat,
            depth: Float,
            material: SCNMaterial
        ) {
            let path = UIBezierPath()
            path.move(to: .zero)
            path.addCurve(
                to: CGPoint(x: direction * span * 0.82, y: rise),
                controlPoint1: CGPoint(x: direction * span * 0.28, y: rise * 1.15),
                controlPoint2: CGPoint(x: direction * span * 0.62, y: rise * 1.2)
            )
            path.addCurve(
                to: CGPoint(x: direction * span, y: -drop * 0.18),
                controlPoint1: CGPoint(x: direction * span * 0.94, y: rise * 0.92),
                controlPoint2: CGPoint(x: direction * span, y: rise * 0.35)
            )
            path.addCurve(
                to: CGPoint(x: direction * span * 0.48, y: -drop),
                controlPoint1: CGPoint(x: direction * span * 0.9, y: -drop * 0.46),
                controlPoint2: CGPoint(x: direction * span * 0.66, y: -drop * 0.96)
            )
            path.addCurve(
                to: .zero,
                controlPoint1: CGPoint(x: direction * span * 0.25, y: -drop * 0.72),
                controlPoint2: CGPoint(x: direction * span * 0.08, y: -drop * 0.32)
            )
            path.close()

            let shape = SCNShape(path: path, extrusionDepth: 0.065)
            shape.chamferRadius = 0.025
            shape.chamferMode = .both
            shape.materials = [material]
            let node = SCNNode(geometry: shape)
            node.position.z = depth
            root.addChildNode(node)
        }

        private func makeJetStream() -> SCNParticleSystem {
            let stream = SCNParticleSystem()
            stream.birthRate = 72
            stream.particleLifeSpan = 0.32
            stream.particleLifeSpanVariation = 0.08
            stream.particleSize = 0.065
            stream.particleSizeVariation = 0.025
            stream.particleColor = UIColor(red: 0.25, green: 0.95, blue: 1, alpha: 1)
            stream.particleColorVariation = SCNVector4(0.08, 0.08, 0.02, 0.12)
            stream.blendMode = .additive
            stream.isLightingEnabled = false
            stream.emitterShape = SCNSphere(radius: 0.06)
            stream.birthLocation = .volume
            stream.emittingDirection = SCNVector3(0, -1, 0)
            stream.spreadingAngle = 11
            stream.particleVelocity = 2.6
            stream.particleVelocityVariation = 0.8
            stream.acceleration = SCNVector3(0, -1.4, 0)
            return stream
        }

        private func material(
            _ color: UIColor,
            metalness: CGFloat = 0.04,
            roughness: CGFloat = 0.42,
            emission: UIColor? = nil,
            opacity: CGFloat = 1
        ) -> SCNMaterial {
            let material = SCNMaterial()
            material.lightingModel = .blinn
            material.diffuse.contents = color
            material.specular.contents = UIColor.white.withAlphaComponent(0.08 + metalness * 0.28)
            material.shininess = max(0.04, (1 - roughness) * 0.55)
            material.emission.contents = emission ?? UIColor.black
            material.transparency = opacity
            material.isDoubleSided = true
            return material
        }

        private func laneX(_ position: Double) -> Float {
            // The old 1.34 spacing put the player centre at ±2.68, wider than
            // the portrait camera frustum near the player. Five lanes still
            // read clearly at 1.0, while the edge centres at ±2.0 leave room
            // for the diver's arms and jet pack inside the visible frame.
            Float((position - Double(TideDiveGame.laneCount - 1) / 2) * 1.0)
        }
    }
}
