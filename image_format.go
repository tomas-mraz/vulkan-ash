// Copyright (c) 2025 Cubyte.online under the AGPL License
// Copyright (c) 2022 Cogent Core. under the BSD-style License
// Copyright (c) 2017 Maxim Kupriianov <max@kc.vc>, under the MIT License

package asch

import (
	"image"

	vk "github.com/tomas-mraz/vulkan"
)

// ImageFormat describes the size and vulkan format of an Image
// If Layers > 1, all must be the same size.
type ImageFormat struct {

	// Size of image
	Size image.Point

	// Image format -- FormatR8g8b8a8Srgb is a standard default
	Format vk.Format

	// number of samples -- set higher for Framebuffer rendering but otherwise default of SampleCount1Bit
	Samples vk.SampleCountFlagBits

	// number of layers for texture arrays
	Layers int
}

// NewImageFormat returns a new ImageFormat with default format and given size
// and number of layers
func NewImageFormat(width, height, layers int) *ImageFormat {
	im := &ImageFormat{}
	im.Defaults()
	im.Size = image.Point{width, height}
	im.Layers = layers
	return im
}

func (im *ImageFormat) Defaults() {
	im.Format = vk.FormatR8g8b8a8Srgb
	im.Samples = vk.SampleCount1Bit
	im.Layers = 1
}

// SetSize sets the width, height
func (im *ImageFormat) SetSize(w, h int) {
	im.Size = image.Point{X: w, Y: h}
}

// Set sets width, height and format
func (im *ImageFormat) Set(w, h int, ft vk.Format) {
	im.SetSize(w, h)
	im.Format = ft
}

// SetMultisample sets the number of multisampling to decrease aliasing
// 4 is typically sufficient.  Values must be power of 2.
func (im *ImageFormat) SetMultisample(nsamp int) {
	ns := vk.SampleCount1Bit
	switch nsamp {
	case 2:
		ns = vk.SampleCount2Bit
	case 4:
		ns = vk.SampleCount4Bit
	case 8:
		ns = vk.SampleCount8Bit
	case 16:
		ns = vk.SampleCount16Bit
	case 32:
		ns = vk.SampleCount32Bit
	case 64:
		ns = vk.SampleCount64Bit
	}
	im.Samples = ns
}
