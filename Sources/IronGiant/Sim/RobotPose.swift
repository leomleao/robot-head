/// The head's pose: turns in radians, and its drift sideways and up in head units.
struct RobotPose: Equatable { var yaw = 0.0, pitch = 0.0, roll = 0.0, x = 0.0, lift = 0.0 }
