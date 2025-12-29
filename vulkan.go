package asch

import (
	"fmt"
	"log/slog"
	"unsafe"

	vk "github.com/tomas-mraz/vulkan"
)

var debug = false

type Vulkan struct {
	Device    vk.Device
	Instance  vk.Instance
	Surface   vk.Surface
	GpuDevice vk.PhysicalDevice
	Queue     vk.Queue
	dbg       vk.DebugReportCallback
}

func SetDebug(state bool) {
	debug = state
}

// NewExtentSize needs for Wayland
func NewExtentSize(width, height int) vk.Extent2D {
	return vk.Extent2D{
		Width:  uint32(width),
		Height: uint32(height),
	}
}

func getDeviceExtensions(gpu vk.PhysicalDevice) (extNames []string) {
	var deviceExtLen uint32
	ret := vk.EnumerateDeviceExtensionProperties(gpu, "", &deviceExtLen, nil)
	check(ret, "vk.EnumerateDeviceExtensionProperties")
	deviceExt := make([]vk.ExtensionProperties, deviceExtLen)
	ret = vk.EnumerateDeviceExtensionProperties(gpu, "", &deviceExtLen, deviceExt)
	check(ret, "vk.EnumerateDeviceExtensionProperties")
	for _, ext := range deviceExt {
		ext.Deref()
		extNames = append(extNames,
			vk.ToString(ext.ExtensionName[:]))
	}
	return extNames
}

func getInstanceExtensions() (extNames []string) {
	var instanceExtLen uint32
	ret := vk.EnumerateInstanceExtensionProperties("", &instanceExtLen, nil)
	check(ret, "vk.EnumerateInstanceExtensionProperties")
	instanceExt := make([]vk.ExtensionProperties, instanceExtLen)
	ret = vk.EnumerateInstanceExtensionProperties("", &instanceExtLen, instanceExt)
	check(ret, "vk.EnumerateInstanceExtensionProperties")
	for _, ext := range instanceExt {
		ext.Deref()
		extNames = append(extNames,
			vk.ToString(ext.ExtensionName[:]))
	}
	return extNames
}

func getPhysicalDevices(instance vk.Instance) ([]vk.PhysicalDevice, error) {
	var gpuCount uint32
	err := vk.Error(vk.EnumeratePhysicalDevices(instance, &gpuCount, nil))
	if err != nil {
		err = fmt.Errorf("vk.EnumeratePhysicalDevices failed with %s", err)
		return nil, err
	}
	if gpuCount == 0 {
		err = fmt.Errorf("getPhysicalDevice: no GPUs found on the system")
		return nil, err
	}
	gpuList := make([]vk.PhysicalDevice, gpuCount)
	err = vk.Error(vk.EnumeratePhysicalDevices(instance, &gpuCount, gpuList))
	if err != nil {
		err = fmt.Errorf("vk.EnumeratePhysicalDevices failed with %s", err)
		return nil, err
	}
	return gpuList, nil
}

func dbgCallbackFunc(flags vk.DebugReportFlags, objectType vk.DebugReportObjectType, object uint64, location uint64, messageCode int32, pLayerPrefix string, pMessage string, pUserData unsafe.Pointer) vk.Bool32 {
	switch {
	case flags&vk.DebugReportFlags(vk.DebugReportErrorBit) != 0:
		slog.Error(fmt.Sprintf("[%d] %s on layer %s", messageCode, pMessage, pLayerPrefix))
	case flags&vk.DebugReportFlags(vk.DebugReportWarningBit) != 0:
		slog.Warn(fmt.Sprintf("[%d] %s on layer %s", messageCode, pMessage, pLayerPrefix))
	default:
		slog.Warn(fmt.Sprintf("unknown debug message %d (layer %s)", messageCode, pLayerPrefix))
	}
	return vk.Bool32(vk.False)
}

// NewDevice create the main Vulkan object holding references to all parts of the Vulkan API
func NewDevice(appName string, instanceExtensions []string, createSurfaceFunc func(instance vk.Instance, window uintptr) (vk.Surface, error), window uintptr) (Vulkan, error) {

	var appInfo = &vk.ApplicationInfo{
		SType:              vk.StructureTypeApplicationInfo,
		ApiVersion:         vk.MakeVersion(1, 0, 0),
		ApplicationVersion: vk.MakeVersion(1, 0, 0),
		PApplicationName:   appName + "\x00",
		PEngineName:        "no engine" + "\x00",
	}

	// Phase 1: vk.CreateInstance with vk.InstanceCreateInfo

	existingExtensions := getInstanceExtensions()
	slog.Debug(fmt.Sprintf("Instance extensions: %v", existingExtensions))

	// instanceExtensions := vk.GetRequiredInstanceExtensions()
	if debug {
		instanceExtensions = append(instanceExtensions,
			"VK_EXT_debug_report\x00")
	}

	// ANDROID:
	// these layers must be included in APK,
	// see Android.mk and ValidationLayers.mk
	instanceLayers := []string{
		"VK_LAYER_KHRONOS_validation\x00",
		// "VK_LAYER_LUNARG_api_dump\x00",
	}

	instanceCreateInfo := vk.InstanceCreateInfo{
		SType:                   vk.StructureTypeInstanceCreateInfo,
		PApplicationInfo:        appInfo,
		EnabledExtensionCount:   uint32(len(instanceExtensions)),
		PpEnabledExtensionNames: instanceExtensions,
		EnabledLayerCount:       uint32(len(instanceLayers)),
		PpEnabledLayerNames:     instanceLayers,
	}
	var vo Vulkan
	err := vk.Error(vk.CreateInstance(&instanceCreateInfo, nil, &vo.Instance))
	if err != nil {
		err = fmt.Errorf("vk.CreateInstance failed with %s", err)
		return vo, err
	} else {
		vk.InitInstance(vo.Instance) // used by MoltenVK
	}

	vo.Surface, err = createSurfaceFunc(vo.Instance, window) // Android use a different way to get surface
	if err != nil {
		vk.DestroyInstance(vo.Instance, nil)
		err = fmt.Errorf("create surface failed with %s", err)
		return vo, err
	}
	var gpuDevices []vk.PhysicalDevice
	if gpuDevices, err = getPhysicalDevices(vo.Instance); err != nil {
		gpuDevices = nil
		vk.DestroySurface(vo.Instance, vo.Surface, nil)
		vk.DestroyInstance(vo.Instance, nil)
		return vo, err
	}

	slog.Debug(fmt.Sprintf("Found %d GPUs", len(gpuDevices)))
	for _, gpu := range gpuDevices {
		var aaa vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(gpu, &aaa)
		aaa.Deref()
		slog.Debug("Listed GPU: " + getCString(aaa.DeviceName[:]))
		aaa.Free()
	}

	vo.GpuDevice = gpuDevices[0] //FIXME select GPU device
	existingExtensions = getDeviceExtensions(vo.GpuDevice)
	slog.Debug(fmt.Sprintf("Device extensions: %v", existingExtensions))

	// Phase 3: vk.CreateDevice with vk.DeviceCreateInfo (a logical device)

	// ANDROID:
	// these layers must be included in APK,
	// see Android.mk and ValidationLayers.mk
	deviceLayers := []string{
		//"VK_LAYER_KHRONOS_validation\x00",
		// "VK_LAYER_LUNARG_api_dump\x00",
	}

	queueCreateInfos := []vk.DeviceQueueCreateInfo{{
		SType:            vk.StructureTypeDeviceQueueCreateInfo,
		QueueCount:       1,
		PQueuePriorities: []float32{1.0},
	}}
	deviceExtensions := []string{
		"VK_KHR_swapchain\x00",
	}
	deviceCreateInfo := vk.DeviceCreateInfo{
		SType:                   vk.StructureTypeDeviceCreateInfo,
		QueueCreateInfoCount:    uint32(len(queueCreateInfos)),
		PQueueCreateInfos:       queueCreateInfos,
		EnabledExtensionCount:   uint32(len(deviceExtensions)),
		PpEnabledExtensionNames: deviceExtensions,
		EnabledLayerCount:       uint32(len(deviceLayers)),
		PpEnabledLayerNames:     deviceLayers,
	}
	var device vk.Device // we choose the first GPU available for this device
	err = vk.Error(vk.CreateDevice(vo.GpuDevice, &deviceCreateInfo, nil, &device))
	if err != nil {
		gpuDevices = nil
		vk.DestroySurface(vo.Instance, vo.Surface, nil)
		vk.DestroyInstance(vo.Instance, nil)
		err = fmt.Errorf("vk.CreateDevice failed with %s", err)
		return vo, err
	} else {
		vo.Device = device
		var queue vk.Queue
		vk.GetDeviceQueue(device, 0, 0, &queue)
		vo.Queue = queue
	}

	if debug {
		// Phase 4: vk.CreateDebugReportCallback

		dbgCreateInfo := vk.DebugReportCallbackCreateInfo{
			SType:       vk.StructureTypeDebugReportCallbackCreateInfo,
			Flags:       vk.DebugReportFlags(vk.DebugReportErrorBit | vk.DebugReportWarningBit),
			PfnCallback: dbgCallbackFunc,
		}
		var dbg vk.DebugReportCallback
		err = vk.Error(vk.CreateDebugReportCallback(vo.Instance, &dbgCreateInfo, nil, &dbg))
		if err != nil {
			err = fmt.Errorf("vk.CreateDebugReportCallback failed with %s", err)
			slog.Warn(err.Error())
			return vo, nil
		}
		vo.dbg = dbg
	}
	return vo, nil
}

func VulkanStart(device vk.Device, swapchain *VulkanSwapchainInfo, r *VulkanRenderInfo, b *VulkanBufferInfo, gfx *VulkanGfxPipelineInfo) {

	clearValues := []vk.ClearValue{
		vk.NewClearValue([]float32{0.098, 0.71, 0.996, 1}),
	}
	for i := range r.cmdBuffers {
		cmdBufferBeginInfo := vk.CommandBufferBeginInfo{
			SType: vk.StructureTypeCommandBufferBeginInfo,
		}
		renderPassBeginInfo := vk.RenderPassBeginInfo{
			SType:       vk.StructureTypeRenderPassBeginInfo,
			RenderPass:  r.RenderPass,
			Framebuffer: swapchain.Framebuffers[i],
			RenderArea: vk.Rect2D{
				Offset: vk.Offset2D{
					X: 0, Y: 0,
				},
				Extent: swapchain.DisplaySize,
			},
			ClearValueCount: 1,
			PClearValues:    clearValues,
		}
		ret := vk.BeginCommandBuffer(r.cmdBuffers[i], &cmdBufferBeginInfo)
		check(ret, "vk.BeginCommandBuffer")

		vk.CmdBeginRenderPass(r.cmdBuffers[i], &renderPassBeginInfo, vk.SubpassContentsInline)
		vk.CmdBindPipeline(r.cmdBuffers[i], vk.PipelineBindPointGraphics, gfx.pipeline)
		offsets := make([]vk.DeviceSize, len(b.vertexBuffers))
		vk.CmdBindVertexBuffers(r.cmdBuffers[i], 0, 1, b.vertexBuffers, offsets)
		vk.CmdDraw(r.cmdBuffers[i], 3, 1, 0, 0)
		vk.CmdEndRenderPass(r.cmdBuffers[i])

		ret = vk.EndCommandBuffer(r.cmdBuffers[i])
		check(ret, "vk.EndCommandBuffer")
	}
	fenceCreateInfo := vk.FenceCreateInfo{
		SType: vk.StructureTypeFenceCreateInfo,
	}
	semaphoreCreateInfo := vk.SemaphoreCreateInfo{
		SType: vk.StructureTypeSemaphoreCreateInfo,
	}
	r.fences = make([]vk.Fence, 1)
	ret := vk.CreateFence(device, &fenceCreateInfo, nil, &r.fences[0])
	check(ret, "vk.CreateFence")
	r.semaphores = make([]vk.Semaphore, 1)
	ret = vk.CreateSemaphore(device, &semaphoreCreateInfo, nil, &r.semaphores[0])
	check(ret, "vk.CreateSemaphore")
}

func DrawFrame(device vk.Device, queue vk.Queue, s VulkanSwapchainInfo, r VulkanRenderInfo) bool {
	var nextIdx uint32
	var err error

	// Phase 1: vk.AcquireNextImage
	// 			get the framebuffer index we should draw in
	//
	//			N.B. non-infinite timeouts may be not yet implemented
	//			by your Vulkan driver

	ret := vk.AcquireNextImage(device, s.DefaultSwapchain(), vk.MaxUint64, r.DefaultSemaphore(), vk.NullFence, &nextIdx)
	if ret == vk.Suboptimal || ret == vk.ErrorOutOfDate {
		slog.Warn("vk.AcquireNextImage returned Suboptimal or ErrorOutOfDate")
	}
	if !(ret == vk.Success || ret == vk.Suboptimal) {
		slog.Error(vk.Error(ret).Error())
		return false
	}

	// Phase 2: vk.QueueSubmit
	//			vk.WaitForFences
	waitStages := []vk.PipelineStageFlags{vk.PipelineStageFlags(vk.PipelineStageColorAttachmentOutputBit)}

	vk.ResetFences(device, 1, r.fences)
	submitInfo := []vk.SubmitInfo{{
		SType:              vk.StructureTypeSubmitInfo,
		WaitSemaphoreCount: 1,
		PWaitSemaphores:    r.semaphores,
		PWaitDstStageMask:  waitStages,
		CommandBufferCount: 1,
		PCommandBuffers:    r.cmdBuffers[nextIdx:],
		//SignalSemaphoreCount: 1,
		//PSignalSemaphores:    r.DefaultSemaphore(),
	}}
	err = vk.Error(vk.QueueSubmit(queue, 1, submitInfo, r.DefaultFence()))
	if err != nil {
		err = fmt.Errorf("vk.QueueSubmit failed with %s", err)
		slog.Warn(err.Error())
		return false
	}

	const timeoutNano = 10 * 1000 * 1000 * 1000 // 10 sec
	err = vk.Error(vk.WaitForFences(device, 1, r.fences, vk.True, timeoutNano))
	if err != nil {
		err = fmt.Errorf("vk.WaitForFences failed with %s", err)
		slog.Warn(err.Error())
		return false
	}

	// Phase 3: vk.QueuePresent

	imageIndices := []uint32{nextIdx}
	presentInfo := vk.PresentInfo{
		SType:          vk.StructureTypePresentInfo,
		SwapchainCount: 1,
		PSwapchains:    s.Swapchains,
		PImageIndices:  imageIndices,
	}
	ret2 := vk.QueuePresent(queue, &presentInfo)
	if ret2 == vk.Suboptimal || ret2 == vk.ErrorOutOfDate {
		slog.Error("vk.QueuePresent returned Suboptimal or ErrorOutOfDate")
	}
	if ret2 != vk.Success {
		slog.Error(vk.Error(ret2).Error())
		return false
	}
	return true
}

func DestroyInOrder(v *Vulkan, swapchain *VulkanSwapchainInfo, r *VulkanRenderInfo, buffer *VulkanBufferInfo, gfx *VulkanGfxPipelineInfo) {

	vk.FreeCommandBuffers(v.Device, r.cmdPool, uint32(len(r.cmdBuffers)), r.cmdBuffers)
	r.cmdBuffers = nil

	vk.DestroyCommandPool(v.Device, r.cmdPool, nil)
	vk.DestroyRenderPass(v.Device, r.RenderPass, nil)
	vk.DestroySemaphore(v.Device, r.DefaultSemaphore(), nil)
	vk.DestroyFence(v.Device, r.DefaultFence(), nil)
	vk.FreeMemory(v.Device, buffer.getDeviceMemory(), nil)

	swapchain.Destroy()
	gfx.Destroy()
	buffer.Destroy()

	vk.DestroyDevice(v.Device, nil)
	if v.dbg != vk.NullDebugReportCallback {
		vk.DestroyDebugReportCallback(v.Instance, v.dbg, nil)
	}
	vk.DestroySurface(v.Instance, v.Surface, nil)
	vk.DestroyInstance(v.Instance, nil)
}
