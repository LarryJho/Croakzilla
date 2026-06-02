extends RigidBody2D

##########################################################
### ROOM SCENE: OBJECT USED FOR LEVEL CREATION         ###
### THROUGH PROCEDURAL MAPS                            ###
##########################################################
### Port to Godot 4.4:                                  ###
### - RectangleShape2D.extents -> .size                ###
###   (in Godot 3 extents was half; in 4 size is the   ###
###   full dimension. The resulting box must be        ###
###   size*2 to preserve the behavior).                ###
##########################################################

var size
var start = false
var end = false


func make_room(_pos, _size):
	position = _pos
	size = _size
	start = false
	end = false

	var s = RectangleShape2D.new()
	s.custom_solver_bias = 0.75
	s.size = size * 2  # equivalent to extents = size in Godot 3
	$CollisionShape2D.shape = s
