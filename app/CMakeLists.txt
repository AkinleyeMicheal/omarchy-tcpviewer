cmake_minimum_required(VERSION 3.21)

project(OmarchyTCPViewer VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.7 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2)
qt_standard_project_setup()
qt_policy(SET QTP0001 NEW)

qt_add_executable(omarchy-tcpviewer
    src/main.cpp
    src/packetmodel.cpp
    src/benchmark.cpp
)

target_link_libraries(omarchy-tcpviewer PRIVATE Qt6::Quick Qt6::QuickControls2)
target_include_directories(omarchy-tcpviewer PRIVATE src)

# Keep the module resource tree flat: qml/Main.qml -> Main.qml.
set_source_files_properties(qml/Main.qml PROPERTIES QT_RESOURCE_ALIAS Main.qml)
set_source_files_properties(qml/PacketTableListView.qml PROPERTIES QT_RESOURCE_ALIAS PacketTableListView.qml)
set_source_files_properties(qml/PacketTableView.qml PROPERTIES QT_RESOURCE_ALIAS PacketTableView.qml)
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
    SOURCES
        src/packetmodel.h
        src/benchmark.h
)
