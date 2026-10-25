using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;

namespace PopGuy;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;

        // Without the +commit suffix the SDK appends to the informational version.
        VersionText.Text = $"Version {App.Version.Split('+')[0]}";
        DataRootText.Text = $"Data folder: {App.DataRoot}";
    }
}
