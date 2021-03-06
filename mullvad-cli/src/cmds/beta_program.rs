use crate::{new_rpc_client, Command, Error, Result, PRODUCT_VERSION};
use clap::value_t_or_exit;

pub struct BetaProgram;

impl Command for BetaProgram {
    fn name(&self) -> &'static str {
        "beta-program"
    }

    fn clap_subcommand(&self) -> clap::App<'static, 'static> {
        clap::SubCommand::with_name(self.name())
            .about("Receive notifications about beta updates")
            .setting(clap::AppSettings::SubcommandRequiredElseHelp)
            .subcommand(
                clap::SubCommand::with_name("set")
                    .about("Change beta notifications setting")
                    .arg(
                        clap::Arg::with_name("policy")
                            .required(true)
                            .possible_values(&["on", "off"]),
                    ),
            )
            .subcommand(clap::SubCommand::with_name("get").about("Get beta notifications setting"))
    }

    fn run(&self, matches: &clap::ArgMatches<'_>) -> Result<()> {
        match matches.subcommand() {
            ("get", Some(_)) => {
                let mut rpc = new_rpc_client()?;
                let settings = rpc.get_settings()?;
                let enabled_str = if settings.show_beta_releases {
                    "on"
                } else {
                    "off"
                };
                println!("Beta program: {}", enabled_str);
                Ok(())
            }
            ("set", Some(matches)) => {
                let enable_str = value_t_or_exit!(matches.value_of("policy"), String);
                let enable = enable_str == "on";

                if !enable && PRODUCT_VERSION.contains("beta") {
                    return Err(Error::InvalidCommand(
                        "The beta program must be enabled while running a beta version",
                    ));
                }

                let mut rpc = new_rpc_client()?;
                rpc.set_show_beta_releases(enable)?;

                println!("Beta program: {}", enable_str);
                Ok(())
            }
            _ => {
                unreachable!("unhandled comand");
            }
        }
    }
}
