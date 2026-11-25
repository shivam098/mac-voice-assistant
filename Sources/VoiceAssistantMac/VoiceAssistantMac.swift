import ThumbFreeMac
import VoiceAssistantCore

/// The Mac desktop layer (docs/design.md): `MacDesktop`, the core's `JarvisDesktop` on Accessibility (AXUIElement),
/// NSWorkspace and CGEvent, for opening and switching apps, reading and clicking what's on screen, tabs, shortcuts and
/// the number badges; and the AI brain's llama-server. Dictation's own Mac parts (Fn, microphone, pill, typing) come
/// from ThumbFreeMac.
public enum VoiceAssistantMac {}
