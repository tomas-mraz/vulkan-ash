// Copyright (c) 2025 Cubyte.online under the AGPL License
// Copyright (c) 2022 Cogent Core. under the BSD-style License
// Copyright (c) 2017 Maxim Kupriianov <max@kc.vc>, under the MIT License

package asch

import (
	"image"

	vk "github.com/tomas-mraz/vulkan"
)

// Render manages various elements needed for rendering,
// including a vulkan RenderPass object,
// which specifies parameters for rendering to a Framebuffer.
// It holds the Depth buffer if one is used, and a multisampling image too.
// The Render object lives on the System, and any associated Surface,
// RenderFrame, and Framebuffers point to it.
type Render struct {

	// system that we belong to and manages all shared resources (Memory, Vars, Values, etc), etc
	//Sys *System

	// the device we're associated with -- this must be the same device that owns the Framebuffer -- e.g., the Surface
	Dev vk.Device

	// image format information for the framebuffer we render to
	Format ImageFormat

	// the associated depth buffer, if set
	Depth Image

	// is true if configured with depth buffer
	HasDepth bool

	// for multisampling, this is the multisampled image that is the actual render target
	Multi Image

	// is true if multsampled image configured
	HasMulti bool

	// host-accessible image that is used to transfer back from a render color attachment to host memory -- requires a different format than color attachment, and is ImageOnHostOnly flagged.
	Grab Image

	// host-accessible buffer for grabbing the depth map -- must go to a buffer and not an image
	//GrabDepth MemBuff

	// set this to true if it is not using a Surface render target (i.e., it is a RenderFrame)
	NotSurface bool

	// values for clearing image when starting render pass
	ClearValues []vk.ClearValue

	// the vulkan renderpass config that clears target first
	VkClearPass vk.RenderPass

	// the vulkan renderpass config that does not clear target first (loads previous)
	VkLoadPass vk.RenderPass
}

// SetSize sets updated size of the render target -- resizes depth and multi buffers as needed
func (rp *Render) SetSize(size image.Point) {
	rp.Format.Size = size
	if rp.HasDepth {
		if rp.Depth.SetSize(size) {
			rp.Depth.ConfigDepthView()
		}
	}
	if rp.HasMulti {
		if rp.Multi.SetSize(size) {
			rp.Multi.ConfigStdView()
		}
	}
}

// SetClearColor sets the RGBA colors to set when starting new render
func (rp *Render) SetClearColor(r, g, b, a float32) {
	if len(rp.ClearValues) == 0 {
		rp.ClearValues = make([]vk.ClearValue, 2)
	}
	rp.ClearValues[0].SetColor([]float32{r, g, b, a})
}

// SetClearDepthStencil sets the depth and stencil values when starting new render
func (rp *Render) SetClearDepthStencil(depth float32, stencil uint32) {
	if len(rp.ClearValues) == 0 {
		rp.ClearValues = make([]vk.ClearValue, 2)
	}
	rp.ClearValues[1].SetDepthStencil(depth, stencil)
}
