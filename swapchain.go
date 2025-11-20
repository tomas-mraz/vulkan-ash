package asch

import (
	"fmt"
	"log"

	vk "github.com/tomas-mraz/vulkan"
)

type VulkanSwapchainInfo struct {
	Device vk.Device

	Swapchains   []vk.Swapchain
	SwapchainLen []uint32

	DisplaySize   vk.Extent2D
	DisplayFormat vk.Format

	Framebuffers []vk.Framebuffer
	DisplayViews []vk.ImageView
}

func NewSwapchain(device vk.Device, gpu vk.PhysicalDevice, surface vk.Surface) (VulkanSwapchainInfo, error) {
	//gpu := v.gpuDevices[0]

	// Phase 1: vk.GetPhysicalDeviceSurfaceCapabilities
	//			vk.GetPhysicalDeviceSurfaceFormats

	var s VulkanSwapchainInfo
	var surfaceCapabilities vk.SurfaceCapabilities
	err := vk.Error(vk.GetPhysicalDeviceSurfaceCapabilities(gpu, surface, &surfaceCapabilities))
	if err != nil {
		err = fmt.Errorf("vk.GetPhysicalDeviceSurfaceCapabilities failed with %s", err)
		return s, err
	}
	var formatCount uint32
	vk.GetPhysicalDeviceSurfaceFormats(gpu, surface, &formatCount, nil)
	formats := make([]vk.SurfaceFormat, formatCount)
	vk.GetPhysicalDeviceSurfaceFormats(gpu, surface, &formatCount, formats)

	log.Println("[INFO] got", formatCount, "physical device surface formats")

	chosenFormat := -1
	for i := 0; i < int(formatCount); i++ {
		formats[i].Deref()
		if formats[i].Format == vk.FormatB8g8r8a8Unorm ||
			formats[i].Format == vk.FormatR8g8b8a8Unorm {
			chosenFormat = i
			break
		}
	}
	if chosenFormat < 0 {
		err := fmt.Errorf("vk.GetPhysicalDeviceSurfaceFormats not found suitable format")
		return s, err
	}

	// Phase 2: vk.CreateSwapchain
	//			create a swapchain with supported capabilities and format

	surfaceCapabilities.Deref()
	s.DisplaySize = surfaceCapabilities.CurrentExtent
	s.DisplaySize.Deref()
	s.DisplayFormat = formats[chosenFormat].Format
	queueFamily := []uint32{0}
	swapchainCreateInfo := vk.SwapchainCreateInfo{
		SType:           vk.StructureTypeSwapchainCreateInfo,
		Surface:         surface,
		MinImageCount:   surfaceCapabilities.MinImageCount,
		ImageFormat:     formats[chosenFormat].Format,
		ImageColorSpace: formats[chosenFormat].ColorSpace,
		ImageExtent:     surfaceCapabilities.CurrentExtent,
		ImageUsage:      vk.ImageUsageFlags(vk.ImageUsageColorAttachmentBit),
		PreTransform:    vk.SurfaceTransformIdentityBit,

		ImageArrayLayers:      1,
		ImageSharingMode:      vk.SharingModeExclusive,
		QueueFamilyIndexCount: 1,
		PQueueFamilyIndices:   queueFamily,
		PresentMode:           vk.PresentModeFifo,
		OldSwapchain:          vk.NullSwapchain,
		Clipped:               vk.False,
	}
	s.Swapchains = make([]vk.Swapchain, 1)
	err = vk.Error(vk.CreateSwapchain(device, &swapchainCreateInfo, nil, &(s.Swapchains[0])))
	if err != nil {
		err = fmt.Errorf("vk.CreateSwapchain failed with %s", err)
		return s, err
	}
	s.SwapchainLen = make([]uint32, 1)
	err = vk.Error(vk.GetSwapchainImages(device, s.DefaultSwapchain(), &(s.SwapchainLen[0]), nil))
	if err != nil {
		err = fmt.Errorf("vk.GetSwapchainImages failed with %s", err)
		return s, err
	}
	for i := range formats {
		formats[i].Free()
	}
	s.Device = device
	return s, nil
}

func (s *VulkanSwapchainInfo) DefaultSwapchain() vk.Swapchain {
	return s.Swapchains[0]
}

func (s *VulkanSwapchainInfo) DefaultSwapchainLen() uint32 {
	return s.SwapchainLen[0]
}

func (s *VulkanSwapchainInfo) CreateFramebuffers(renderPass vk.RenderPass, depthView vk.ImageView) error {
	// Phase 1: vk.GetSwapchainImages

	var swapchainImagesCount uint32
	err := vk.Error(vk.GetSwapchainImages(s.Device, s.DefaultSwapchain(), &swapchainImagesCount, nil))
	if err != nil {
		err = fmt.Errorf("vk.GetSwapchainImages failed with %s", err)
		return err
	}
	swapchainImages := make([]vk.Image, swapchainImagesCount)
	vk.GetSwapchainImages(s.Device, s.DefaultSwapchain(), &swapchainImagesCount, swapchainImages)

	// Phase 2: vk.CreateImageView
	//			create image view for each swapchain image

	s.DisplayViews = make([]vk.ImageView, len(swapchainImages))
	for i := range s.DisplayViews {
		viewCreateInfo := vk.ImageViewCreateInfo{
			SType:    vk.StructureTypeImageViewCreateInfo,
			Image:    swapchainImages[i],
			ViewType: vk.ImageViewType2d,
			Format:   s.DisplayFormat,
			Components: vk.ComponentMapping{
				R: vk.ComponentSwizzleR,
				G: vk.ComponentSwizzleG,
				B: vk.ComponentSwizzleB,
				A: vk.ComponentSwizzleA,
			},
			SubresourceRange: vk.ImageSubresourceRange{
				AspectMask: vk.ImageAspectFlags(vk.ImageAspectColorBit),
				LevelCount: 1,
				LayerCount: 1,
			},
		}
		err := vk.Error(vk.CreateImageView(s.Device, &viewCreateInfo, nil, &s.DisplayViews[i]))
		if err != nil {
			err = fmt.Errorf("vk.CreateImageView failed with %s", err)
			return err // bail out
		}
	}
	swapchainImages = nil

	// Phase 3: vk.CreateFramebuffer
	//			create a framebuffer from each swapchain image

	s.Framebuffers = make([]vk.Framebuffer, s.DefaultSwapchainLen())
	for i := range s.Framebuffers {
		attachments := []vk.ImageView{
			s.DisplayViews[i], depthView,
		}
		fbCreateInfo := vk.FramebufferCreateInfo{
			SType:           vk.StructureTypeFramebufferCreateInfo,
			RenderPass:      renderPass,
			Layers:          1,
			AttachmentCount: 1, // 2 if has depthView
			PAttachments:    attachments,
			Width:           s.DisplaySize.Width,
			Height:          s.DisplaySize.Height,
		}
		if depthView != vk.NullImageView {
			fbCreateInfo.AttachmentCount = 2
		}
		err := vk.Error(vk.CreateFramebuffer(s.Device, &fbCreateInfo, nil, &s.Framebuffers[i]))
		if err != nil {
			err = fmt.Errorf("vk.CreateFramebuffer failed with %s", err)
			return err // bail out
		}
	}
	return nil
}

func (s *VulkanSwapchainInfo) Destroy() {
	for i := uint32(0); i < s.DefaultSwapchainLen(); i++ {
		vk.DestroyFramebuffer(s.Device, s.Framebuffers[i], nil)
		vk.DestroyImageView(s.Device, s.DisplayViews[i], nil)
	}
	s.Framebuffers = nil
	s.DisplayViews = nil
	for i := range s.Swapchains {
		vk.DestroySwapchain(s.Device, s.Swapchains[i], nil)
	}
}
