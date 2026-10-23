cmake_minimum_required(VERSION 3.21)

project(OmarchyTCPViewer VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.7 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2 Network)
qt_standard_project_setup()
qt_policy(SET QTP0001 NEW)

qt_add_executable(omarchy-tcpviewer
    src/main.cpp
    src/packetmodel.cpp
    src/packetdetailmodel.cpp
    src/hexview.cpp
    src/followstreammodel.cpp
    src/endpointstatsmodel.cpp
    src/benchmark.cpp
    src/daemonclient.cpp
    src/sessioncontroller.cpp
    src/packetinspector.cpp
)

target_link_libraries(omarchy-tcpviewer PRIVATE Qt6::Quick Qt6::QuickControls2 Qt6::Network)
target_include_directories(omarchy-tcpviewer PRIVATE src)

# Keep the module resource tree flat: qml/Main.qml -> Main.qml.
set_source_files_properties(qml/Main.qml PROPERTIES QT_RESOURCE_ALIAS Main.qml)
set_source_files_properties(qml/PacketTableListView.qml PROPERTIES QT_RESOURCE_ALIAS PacketTableListView.qml)
set_source_files_properties(qml/PacketTableView.qml PROPERTIES QT_RESOURCE_ALIAS PacketTableView.qml)
set_source_files_properties(qml/Sidebar.qml PROPERTIES QT_RESOURCE_ALIAS Sidebar.qml)
set_source_files_properties(qml/QuickFilterBar.qml PROPERTIES QT_RESOURCE_ALIAS QuickFilterBar.qml)
set_source_files_properties(qml/StatusStrip.qml PROPERTIES QT_RESOURCE_ALIAS StatusStrip.qml)
set_source_files_properties(qml/EmptyState.qml PROPERTIES QT_RESOURCE_ALIAS EmptyState.qml)
set_source_files_properties(qml/Inspector.qml PROPERTIES QT_RESOURCE_ALIAS Inspector.qml)
set_source_files_properties(qml/FollowStreamWindow.qml PROPERTIES QT_RESOURCE_ALIAS FollowStreamWindow.qml)
set_source_files_properties(qml/EndpointStatisticsWindow.qml PROPERTIES QT_RESOURCE_ALIAS EndpointStatisticsWindow.qml)
set_source_files_properties(qml/Theme.qml PROPERTIES
    QT_RESOURCE_ALIAS Theme.qml
    QT_QML_SINGLETON_TYPE TRUE
)

qt_add_qml_module(omarchy-tcpviewer
    URI Omarchy.TCPViewer
    VERSION 0.1
    QML_FILES
        qml/Main.qml
        qml/Theme.qml
        qml/PacketTableListView.qml
        qml/PacketTableView.qml
        qml/Sidebar.qml
        qml/QuickFilterBar.qml
        qml/StatusStrip.qml
        qml/EmptyState.qml
        qml/Inspector.qml
        qml/FollowStreamWindow.qml
        qml/EndpointStatisticsWindow.qml
    SOURCES
        src/packetmodel.h
        src/packetdetailmodel.h
        src/hexview.h
        src/followstreammodel.h
        src/endpointstatsmodel.h
        src/benchmark.h
        src/daemonclient.h
        src/sessioncontroller.h
        src/packetinspector.h
)
