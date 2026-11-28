import Foundation

/// Phil, 2026-11-21: each model's own light (ModelLighting.swift). A SceneKit surface shader step: the surface colour
/// is multiplied by the model's tint and, with a side light, by how much the surface faces that light (0.45 turned away,
/// 1.3 facing it, as ModelLight.shade). The light's way is in room coordinates; the frame's view transform turns it to
/// the camera's, as the normal is. A fragment step (after lighting), because an unlit scan or cut-out ignores a
/// surface step's colour. Kept on its own so the light tests can render it on a Mac.
enum ModelLightShader {
    static let source = """
    #pragma arguments
    float3 resetTint;
    float3 resetLightWay;
    float resetSideLight;
    #pragma body
    float3 resetLight = normalize((scn_frame.viewTransform * float4(resetLightWay, 0.0)).xyz);
    float resetFacing = clamp(dot(normalize(_surface.normal), resetLight), 0.0, 1.0);
    _output.color.rgb *= resetTint * mix(1.0, 0.45 + 0.85 * resetFacing, resetSideLight);
    """
}
