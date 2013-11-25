//
//  main.m
//  MACDaemonTest
//
//  Created by Ankita Kalangutkar on 07/11/13.
//  Copyright (c) 2013 creative capsule. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOMessage.h>
#include <IOKit/IOCFPlugIn.h>
#import <IOKit/usb/IOUSBLib.h>

#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

#include <IOKit/IOBSD.h>
#include <IOKit/storage/IOCDMedia.h>
#include <IOKit/storage/IOMedia.h>
#include <IOKit/storage/IOCDTypes.h>
#include <IOKit/storage/IOMediaBSDClient.h>

#include <IOKit/serial/IOSerialKeys.h>
#include <IOKit/serial/ioss.h>

#include <CoreFoundation/CoreFoundation.h>

#include <stdio.h>
#include <math.h>
//#include <hex2c.h>

#define USE_ASYNC_IO
#define kTestMessage        "Bulk I/O Test"

#define k8051_USBCS         0x7f92

#define kOurVendorID        0x05ac    //Vendor ID of the USB device

#define kOurProductID           0x129a    //Product ID of device BEFORE it

//is programmed (raw device)

#define kOurProductIDBulkTest   4098    //Product ID of device AFTER it is

//programmed (bulk test device)
//Global variables

static IONotificationPortRef    gNotifyPort;

static io_iterator_t            gRawAddedIter;

static io_iterator_t            gRawRemovedIter;

static io_iterator_t            gBulkTestAddedIter;

static io_iterator_t            gBulkTestRemovedIter;

static char                     gBuffer[64];


IOReturn ConfigureDevice(IOUSBDeviceInterface **dev)

{
    
    UInt8                           numConfig;
    
    IOReturn                        kr;
    
    IOUSBConfigurationDescriptorPtr configDesc;
    
    
    
    //Get the number of configurations. The sample code always chooses
    
    //the first configuration (at index 0) but your code may need a
    
    //different one
    
    kr = (*dev)->GetNumberOfConfigurations(dev, &numConfig);
    
    if (!numConfig)
        
        return -1;
    
    
    
    //Get the configuration descriptor for index 0
    
    kr = (*dev)->GetConfigurationDescriptorPtr(dev, 0, &configDesc);
    
    if (kr)
    { 
        printf("Couldn’t get configuration descriptor for index %d (err =%08x)\n", 0, kr);
        
        return -1;
        
    }
    
    
    
    //Set the device’s configuration. The configuration value is found in
    
    //the bConfigurationValue field of the configuration descriptor
    
    kr = (*dev)->SetConfiguration(dev, configDesc->bConfigurationValue);
    
    if (kr)
        
    {
        
        printf("Couldn’t set configuration to value %d (err = %08x)\n", 0,
               
               kr);
        
        return -1;
        
    }
    
    return kIOReturnSuccess;
    
}

IOReturn FindInterfaces (IOUSBDeviceInterface **device)
{
    IOReturn kr = 0;
    IOUSBFindInterfaceRequest request;
    io_iterator_t iterator;
    io_service_t usbInterface;
    IOCFPlugInInterface **plugInInterface = NULL;
    IOUSBInterfaceInterface **interface = NULL;
    HRESULT result;
    sint32 score;
    UInt8 interfaceClass;
    UInt8 interfaceSubClass;
    UInt8 interfaceNumEndPoints;
    int pipeRef;
    
#ifndef USB_ASYNC_IO
    UInt32 numBytesRead;
    UInt32 i;
#else
    CFRunLoopSourceRef runLoopSource;
#endif
    
    request.bInterfaceClass = kIOUSBFindInterfaceDontCare;
    request.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    request.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    request.bAlternateSetting = kIOUSBFindInterfaceDontCare;
    
    // iterate through interfsces on the device
    kr = (*device) -> CreateInterfaceIterator (device, &request, &iterator);
    while ((usbInterface = IOIteratorNext(iterator)))
    {
        // create intermediate plug in
        kr = IOCreatePlugInInterfaceForService(usbInterface, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plugInInterface, &score);
        
        // release the usbInterface object after getting the plugin
        kr = IOObjectRelease(usbInterface);
        if ((kr != kIOReturnSuccess) || !plugInInterface)
        {
            printf("Unable to create a plug-in (%08x)\n", kr);
            break;
        }
        
        // now create the device interface for the interface
        result = (*plugInInterface) -> QueryInterface (plugInInterface, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (LPVOID *) &interface);
        
        // now release intermediate plugin
        (*plugInInterface) -> Release (plugInInterface);
        
        if (result || !interface)
        {
            printf("Couldn’t create a device interface for the interface(%08x)\n", (int) result);
            break;
        }
        
        // get interfece class and subclass
        kr = (*interface) -> GetInterfaceClass (interface, &interfaceClass);
        kr = (*interface) -> GetInterfaceSubClass (interface, &interfaceSubClass);
        printf("Interface class %d, subclass %d\n", interfaceClass,interfaceSubClass);
        
        //Now open the interface. This will cause the pipes associated with
        //the endpoints in the interface descriptor to be instantiated
        kr = (*interface) ->USBInterfaceOpen (interface);
        if (kr != kIOReturnSuccess)
        {
            printf("Unable to open interface\n");
            (void) (*interface) -> Release (interface);
            break;
        }
        
        // get the no of end points associated with this interface
        kr= (*interface) -> GetNumEndpoints (interface, &interfaceNumEndPoints);
        if (kr != kIOReturnSuccess)
        {
            printf("Unable to get number of endpoints (%08x)\n", kr);
            (void) (*interface)->USBInterfaceClose(interface);
            (void) (*interface)->Release(interface);
            break;
        }
        
        
        printf("Interface has %d endpoints\n", interfaceNumEndPoints);
        
        //Access each pipe in turn, starting with the pipe at index 1
        //The pipe at index 0 is the default control pipe and should be
        //accessed using (*usbDevice)->DeviceRequest() instead
        for (pipeRef = 1; pipeRef <= interfaceNumEndPoints; pipeRef++)
        {
            IOReturn kr2;
            UInt8 direction;
            UInt8 number;
            UInt8 transferType;
            UInt16 maxPacketSize;
            UInt8 interval;
            char *message;
            
            kr2 = (*interface) ->GetPipeProperties (interface,pipeRef, &direction,&number,&transferType, &maxPacketSize, &interval);
            if (kr2 != kIOReturnSuccess)
            {
                printf("Unable to get properties of pipe %d (%08x)\n", pipeRef, kr2);
            }
            else
            {
                printf("PipeRef %d: ",pipeRef);
                switch (direction)
                {
                    case kUSBOut:
                        message = "out";
                        break;
                        
                    case kUSBIn:
                        message = "in";
                        break;
                        
                    case kUSBNone:
                        message = "none";
                        break;
                        
                    case kUSBAnyDirn:
                        message = "any";
                        break;
                        
                    default:
                        message ="????";
                        break;
                }
                printf("message: %s",message);
                
                switch (transferType)
                {
                    case kUSBControl:
                        message = "control";
                        break;
                        
                    case kUSBIsoc:
                        message = "isoc";
                        break;
                        
                    case kUSBBulk:
                        message = "bulk";
                        break;

                    case kUSBInterrupt:
                        message = "interrupt";
                        break;

                    case kUSBAnyType:
                        message = "any";
                        break;
                        
                    default:
                        break;
                }
                
            printf("transfer type %s, maxPacketSize %d\n", message,maxPacketSize);;
            
            }
        }
    
    }

    
    return kr;
}

void RawDeviceAdded (void *refCon, io_iterator_t iterator)
{
    kern_return_t kr;
    io_service_t usbDevice;
    IOCFPlugInInterface **plugIninterface = NULL;
    IOUSBDeviceInterface **dev = NULL;
    HRESULT result;
    SInt32 score;
    UInt16 vendor;
    UInt16 product;
    UInt16 release;
    
     printf("New Device added.\n");
    
    //while ((usbDevice = IOIteratorNext(iterator)))
     while ((usbDevice = IOIteratorNext(iterator)))
    {
        // create an intermediate plug-in
        kr = IOCreatePlugInInterfaceForService(usbDevice, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugIninterface, &score);
        
        // dont need the device after intermediate plugin is created
        kr = IOObjectRelease(usbDevice);
        if ((kIOReturnSuccess != kr) || !plugIninterface)
        {
            printf("unable to create plugin");
            continue;
        }
        
        // now create the device interface
        result = (*plugIninterface)->QueryInterface (plugIninterface,
                                                     CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                                                     (LPVOID *)&dev);
        
        // dont need the intermediate plugin after device interface is created
        (*plugIninterface) -> Release (plugIninterface);
        
        if (result || !dev)
        {
            printf("Couldn’t create a device interface (%08x)\n",
                   
                   (int) result);
            
            continue;
        }
        
        // check these values for confirmation
        kr = (*dev) -> GetDeviceVendor (dev, &vendor);
        kr = (*dev) -> GetDeviceProduct (dev, &product);
        kr = (* dev) -> GetDeviceReleaseNumber (dev, &release);
        if ((vendor != kOurVendorID) || (product != kOurProductID) || (release != 1))
        {
            
                printf("Found unwanted device (vendor = %d, product = %d)\n",vendor, product);
                (void) (*dev)->Release(dev);
                continue;
            
        }
        
        // open the device to change its state
        kr = (*dev) -> USBDeviceOpen (dev);
        if (kr != kIOReturnSuccess)
        {
            printf("Unable to open device: %08x\n", kr);
            
            (void) (*dev)->Release(dev);
            (void) (*dev) -> Release (dev);
            continue;
        }
        
        // configure device
        kr = ConfigureDevice(dev);
        if (kr != kIOReturnSuccess)
        {
            printf("unable to configure device");
            (void) (*dev) -> USBDeviceClose (dev);
            //Close this device and release object
            kr = (*dev)->USBDeviceClose(dev);
            kr = (*dev)->Release(dev);
            
        }
        //Download firmware to device
            // to do
        
        // get interfaces
        kr = FindInterfaces (dev);
        if (kr != kIOReturnSuccess)
        {
            printf("Unable to find interfaces on device: %08x\n",kr);;
            (*dev) -> USBDeviceClose (dev);
            (*dev) -> Release (dev);
            continue;
        }
        
        //If using synchronous IO, close and release the device interface here
        
#ifndef USB_ASYNC_IO
        
        kr = (*dev)->USBDeviceClose(dev);
        
        kr = (*dev)->Release(dev);
        
#endif
        

    }
}

void RawDeviceRemoved (void *refCon, io_iterator_t iterator)
{
    kern_return_t kr;
    io_service_t object;
    
    while ((object = IOIteratorNext(iterator)))
    {
        kr = IOObjectRelease(object);
        if (kr != kIOReturnSuccess)
        {
            printf("Couldn’t release raw device object: %08x\n", kr);
            
            continue;
        }
    }
}

void SignalHandler(int sigraised)
{
    fprintf(stderr, "\nInterrupted.\n");
    
    exit(0);
}


int main(int argc, char *argv[])
{
    mach_port_t masterPort;
    CFMutableDictionaryRef matchingDict;
    CFRunLoopSourceRef runLoopSource;
    CFNumberRef				numberRef;
    kern_return_t kr;
    sint32 usbVendor = kOurVendorID;
    sint32 usbProduct = kOurProductID;
    sig_t					oldHandler;
    
    // Get command line arguments, if any
    
//    if (argc > 1)
//    {
//        fprintf(stderr, "Looking for devices matching vendor ID=%d and product ID=%d.\n", usbVendor, usbProduct);
//        usbVendor = atoi(argv[1]);
//    }
//    if (argc > 2)
//    {
//        usbProduct = atoi(argv[2]);
//    }
    // Set up a signal handler so we can clean up when we're interrupted from the command line
    // Otherwise we stay in our run loop forever.
    oldHandler = signal(SIGINT, SignalHandler);
    if (oldHandler == SIG_ERR) {
        fprintf(stderr, "Could not establish new signal handler.");
	}
    
    fprintf(stderr, "Looking for devices matching vendor ID=%d and product ID=%d.\n", usbVendor, usbProduct);
    
    // create master port for communicating with I/O kit port
    kr = IOMasterPort(MACH_PORT_NULL, &masterPort);
    if (kr || !masterPort)
    {
        printf("ERR: Couldn’t create a master I/O Kit port(%08x)\n", kr);
        
        return -1;
    }
    
    // set up matching dictionary for class IOUSBDevice and its subclass
    matchingDict = IOServiceMatching(kIOUSBDeviceClassName);
    if (!matchingDict)
    {
        printf("could not create USB matching dict");
        return -1;
    }
    //Add the vendor and product IDs to the matching dictionary.
    //This is the second key in the table of device-matching keys of the
    //USB Common Class Specification
    numberRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usbVendor);
    CFDictionarySetValue(matchingDict,
                         CFSTR(kUSBVendorID),
                         numberRef);
    CFRelease(numberRef);
    
    numberRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usbProduct);
    CFDictionarySetValue(matchingDict, CFSTR(kUSBProductID), numberRef);
    CFRelease(numberRef);
    
    numberRef = NULL;
    
    //To set up asynchronous notifications, create a notification port and
    //add its run loop event source to the program’s run loop
    gNotifyPort = IONotificationPortCreate(masterPort);
    runLoopSource = IONotificationPortGetRunLoopSource(gNotifyPort);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopDefaultMode);
    
    //Now set up two notifications: one to be called when a raw device
    //is first matched by the I/O Kit and another to be called when the
    //device is terminated
    //Notification of first match:
    kr = IOServiceAddMatchingNotification(gNotifyPort,
                                          kIOFirstMatchNotification,
                                          matchingDict,
                                          RawDeviceAdded,
                                          NULL, &gRawAddedIter);
    
    //Iterate over set of matching devices to access already-present devices
    //and to arm the notification
    RawDeviceAdded(NULL, gRawAddedIter);
    
    //Notification of termination:
    kr = IOServiceAddMatchingNotification(gNotifyPort,
                                          kIOTerminatedNotification,
                                          matchingDict,
                                          RawDeviceRemoved,
                                          NULL,
                                          &gRawRemovedIter);
    
    //Iterate over set of matching devices to release each one and to
    //arm the notification
    RawDeviceRemoved(NULL, gRawRemovedIter);
    
    //Start the run loop so notifications will be received
    CFRunLoopRun();
    
    //Because the run loop will run forever until interrupted,
    //the program should never reach this point
    return 0;
    
    //return NSApplicationMain(argc, (const char **)argv);
}
