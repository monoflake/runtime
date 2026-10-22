# The machine driver's images, each built for every architecture a machine runs, RFC vr5lw.

# Where a release writes one architecture's archive, and the image it pushes by digest from the
# same build, so both hold one manifest; left empty, a build exports nothing.
variable "ARCHIVE" {
	default = ""
}

variable "IMAGE" {
	default = ""
}

# The version the archive names its image by, as Docker Hub tags it.
variable "VERSION" {
	default = ""
}

group "default" {
	targets = ["workerd", "wasmtime"]
}

target "release" {
	output = ARCHIVE == "" ? [] : [
		"type=oci,dest=${ARCHIVE},name=${IMAGE}:${VERSION}",
		"type=image,name=${IMAGE},push-by-digest=true,name-canonical=true,push=true",
	]
}

target "workerd" {
	inherits = ["release"]
	context = "workerd"
	platforms = ["linux/amd64", "linux/arm64"]
}

target "wasmtime" {
	inherits = ["release"]
	context = "wasmtime"
	platforms = ["linux/amd64", "linux/arm64"]
}
